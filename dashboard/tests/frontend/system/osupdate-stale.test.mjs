import assert from "node:assert/strict";
import { test } from "node:test";

import { installFreshness } from "../../../mining_dashboard/web/static/app/freshness.mjs";
import {
  osAction,
  OsUpdateControl,
  pollOsResult,
} from "../../../mining_dashboard/web/static/system/osupdate.mjs";
import { installStaleProbe, reply, STALE, withFetch } from "../helpers/stalepage.mjs";

const ID = "22222222-2222-4222-8222-222222222222";

const shown = async (fn) => {
  try {
    await fn();
  } catch (e) {
    return String((e && e.message) || e);
  }
  assert.fail("expected a rejection");
};

for (const [name, stub] of [
  ["401 with a body", async () => reply(401, "login required")],
  ["403", async () => reply(403)],
  ["a network rejection", async () => Promise.reject(new TypeError("Failed to fetch"))],
  ["a Safari network rejection", async () => Promise.reject(new TypeError("Load failed"))],
]) {
  test(`osAction: ${name} shows the stale-page message and reloads once /api/state answers`, async () => {
    const probe = installStaleProbe();
    const text = await withFetch(stub, () => shown(() => osAction("install")));
    await probe.settle();
    assert.equal(text, STALE);
    assert.equal(probe.reloads.length, 1);
  });
}

test("osAction: 401 never reloads before /api/state answers ok", async () => {
  const reloads = [];
  const answers = [false, false, true];
  installFreshness({
    reload: () => reloads.push(1),
    store: { getItem: () => null, setItem: () => {} },
    fetchFn: async () => ({ ok: answers.shift() }),
    sleep: async () => {},
  });
  await withFetch(
    async () => reply(401),
    () => shown(() => osAction("check")),
  );
  await new Promise((r) => setImmediate(r));
  assert.equal(answers.length, 0);
  assert.equal(reloads.length, 1);
});

test("osAction: a plain-text 500 shows the body, an empty one shows HTTP 500", async () => {
  const probe = installStaleProbe();
  const body = await withFetch(
    async () => reply(500, "control spool is full"),
    () => shown(() => osAction("download", "v1.2.3")),
  );
  const bare = await withFetch(
    async () => reply(500),
    () => shown(() => osAction("download", "v1.2.3")),
  );
  await probe.settle();
  assert.equal(body, "control spool is full");
  assert.equal(bare, "HTTP 500");
  assert.equal(probe.reloads.length, 0);
});

test("osAction: a 202 still resolves to the intent id", async () => {
  const id = await withFetch(
    async () => reply(202, "", { id: ID }),
    () => osAction("check"),
  );
  assert.equal(id, ID);
});

test("pollOsResult: 401 and 403 take the stale-page path, a plain-text 500 shows its body", async () => {
  const probe = installStaleProbe();
  for (const status of [401, 403]) {
    const text = await withFetch(
      async () => reply(status),
      () => shown(() => pollOsResult(ID)),
    );
    assert.equal(text, STALE);
  }
  await probe.settle();
  assert.equal(probe.reloads.length, 1);
  const body = await withFetch(
    async () => reply(500, "runner crashed"),
    () => shown(() => pollOsResult(ID)),
  );
  assert.equal(body, "runner crashed");
});

test("pollOsResult: 502, 503, 504 and dropped connections are still ridden out", async () => {
  const probe = installStaleProbe();
  const steps = [
    () => reply(502),
    () => reply(503),
    () => reply(504),
    () => Promise.reject(new TypeError("Failed to fetch")),
    () => reply(200, "", { status: "checked" }),
  ];
  const out = await withFetch(
    async () => steps.shift()(),
    () => pollOsResult(ID),
  );
  await probe.settle();
  assert.equal(out.status, "checked");
  assert.equal(probe.reloads.length, 0);
});

test("a stale-page failure surfaces in the error pane as the message alone", async () => {
  installStaleProbe();
  const view = new OsUpdateControl({ os: {}, enabled: true });
  view.setState = (patch) => Object.assign(view.state, patch);
  await withFetch(
    async () => reply(403),
    () => view.check(),
  );
  assert.equal(view.state.phase, "error");
  assert.equal(view.state.error, STALE);
});

test("an automatic reload is held through every in-progress phase and released on leaving them", () => {
  const reloads = [];
  const f = installFreshness({
    reload: () => reloads.push(1),
    store: { getItem: () => null, setItem: () => {} },
  });
  const view = new OsUpdateControl({ os: { step: "idle" }, enabled: true });
  f.goodPoll("v1", false);
  for (const phase of ["checking", "downloading", "verifying", "installing"]) {
    view.state.phase = phase;
    view.componentDidUpdate();
    f.goodPoll("v2", false);
    assert.equal(reloads.length, 0, phase);
  }
  view.state.phase = "error";
  view.componentDidUpdate();
  assert.equal(reloads.length, 1);
});

test("unmounting mid-flow releases the hold", () => {
  const reloads = [];
  const f = installFreshness({
    reload: () => reloads.push(1),
    store: { getItem: () => null, setItem: () => {} },
  });
  const view = new OsUpdateControl({ os: { step: "idle" }, enabled: true });
  view.state.phase = "downloading";
  view.componentDidUpdate();
  f.goodPoll("v1", false);
  f.goodPoll("v2", false);
  assert.equal(reloads.length, 0);
  view.componentWillUnmount();
  assert.equal(reloads.length, 1);
});
