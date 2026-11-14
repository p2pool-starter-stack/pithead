import assert from "node:assert/strict";
import { test } from "node:test";

import {
  ConfigView,
  pollResult,
  runUpgrade,
  UpgradeControl,
} from "../../../mining_dashboard/web/static/config/configview.mjs";
import { controlCommitResult } from "../../../mining_dashboard/web/static/config/controlclient.mjs";
import { installStaleProbe, reply, STALE, withFetch } from "../helpers/stalepage.mjs";

const ID = "33333333-3333-4333-8333-333333333333";
const reject = () => Promise.reject(new TypeError("Failed to fetch"));

function viewWith(preview = { id: ID, destructive: false }) {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  view.state.preview = preview;
  view.state.candidate = {};
  return view;
}

const shown = async (fn) => {
  try {
    await fn();
  } catch (e) {
    return String(e);
  }
  assert.fail("expected a rejection");
};

test("controlCommitResult shows a non-JSON body as text instead of a SyntaxError", async () => {
  const text = await shown(() =>
    controlCommitResult({ text: async () => "gateway exploded" }, ID, async () => ({})),
  );
  assert.equal(text, "gateway exploded");
});

test("controlCommitResult still parses JSON and polls an empty body", async () => {
  const applied = await controlCommitResult(
    { text: async () => '{"status":"applied"}' },
    ID,
    async () => assert.fail("no poll"),
  );
  assert.equal(applied.status, "applied");
  const polled = await controlCommitResult({ text: async () => "" }, ID, async () => ({
    status: "applied",
  }));
  assert.equal(polled.status, "applied");
});

for (const [name, stub] of [
  ["401 with a body", async () => reply(401, "login required")],
  ["403", async () => reply(403)],
]) {
  test(`commit: ${name} takes the stale-page path`, async () => {
    const probe = installStaleProbe();
    const view = viewWith();
    await withFetch(stub, () => view.commit());
    await probe.settle();
    assert.equal(view.state.phase, "error");
    assert.equal(view.state.error, STALE);
    assert.equal(probe.reloads.length, 1);
  });
}

test("commit: a plain-text 500 shows its body and an empty one shows HTTP 500", async () => {
  const probe = installStaleProbe();
  const view = viewWith();
  await withFetch(async () => reply(500, "disk full"), () => view.commit());
  assert.equal(view.state.error, "disk full");
  await withFetch(async () => reply(500), () => view.commit());
  assert.equal(view.state.error, "HTTP 500");
  await probe.settle();
  assert.equal(probe.reloads.length, 0);
});

test("commit: a 502 or a dropped connection mid-commit rides out via the poll, not the stale path", async () => {
  for (const first of [async () => reply(502), reject]) {
    const probe = installStaleProbe();
    const view = viewWith();
    let polled = null;
    view.poll = async (id, skip) => {
      polled = [id, skip];
      return { status: "applied" };
    };
    await withFetch(first, () => view.commit());
    await probe.settle();
    assert.deepEqual(polled, [ID, "previewed"]);
    assert.equal(view.state.phase, "done");
    assert.equal(probe.reloads.length, 0);
  }
});

test("commit: a non-JSON 200 body shows as text", async () => {
  installStaleProbe();
  const view = viewWith();
  await withFetch(async () => reply(200, "<html>proxy error</html>"), () => view.commit());
  assert.equal(view.state.phase, "error");
  assert.equal(view.state.error, "<html>proxy error</html>");
});

test("preview: a network rejection or 401/403 shows the stale message and reloads", async () => {
  for (const stub of [reject, async () => reply(401), async () => reply(403)]) {
    const probe = installStaleProbe();
    const view = viewWith();
    view.state.candidate = {};
    view.state.pristine = "{}";
    view.state.editText = "{}";
    await withFetch(stub, () => view.save());
    await probe.settle();
    assert.equal(view.state.error, STALE);
    assert.equal(probe.reloads.length, 1);
  }
});

test("preview: a plain-text 500 shows its body", async () => {
  installStaleProbe();
  const view = viewWith();
  view.state.pristine = "{}";
  await withFetch(async () => reply(500, "preview crashed"), () => view.save());
  assert.equal(view.state.error, "preview crashed");
});

test("load: 403 shows the stale message and reloads", async () => {
  const probe = installStaleProbe();
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  await withFetch(async () => reply(403), () => view.load());
  await probe.settle();
  assert.equal(view.state.phase, "error");
  assert.equal(view.state.error, STALE);
  assert.equal(probe.reloads.length, 1);
});

for (const [name, stub, expected] of [
  ["401", async () => reply(401, "login"), STALE],
  ["403", async () => reply(403), STALE],
  ["a network rejection", reject, STALE],
  ["a plain-text 500", async () => reply(500, "upgrade refused"), "upgrade refused"],
  ["an empty 500", async () => reply(500), "HTTP 500"],
]) {
  test(`runUpgrade: ${name} shows ${expected === STALE ? "the stale message" : `"${expected}"`}`, async () => {
    const probe = installStaleProbe();
    const text = await withFetch(stub, () => shown(() => runUpgrade("v9.9.9")));
    await probe.settle();
    assert.equal(text, expected);
    assert.equal(probe.reloads.length, expected === STALE ? 1 : 0);
  });
}

test("UpgradeControl shows the stale message alone in its failure result", async () => {
  installStaleProbe();
  const control = new UpgradeControl({ update: { available: true, latest: "v9.9.9" }, enabled: true });
  control.setState = (patch) => Object.assign(control.state, patch);
  await withFetch(async () => reply(403), () => control.run());
  assert.equal(control.state.phase, "failed");
  assert.equal(control.state.result.error, STALE);
});

test("pollResult: 401 and 403 take the stale path; a 500 shows its body; 502/503/504 and drops ride out", async () => {
  const probe = installStaleProbe();
  for (const status of [401, 403]) {
    const text = await withFetch(async () => reply(status), () => shown(() => pollResult(ID)));
    assert.equal(text, STALE);
  }
  await probe.settle();
  assert.equal(probe.reloads.length, 1);
  assert.equal(
    await withFetch(async () => reply(500, "result store broke"), () => shown(() => pollResult(ID))),
    "result store broke",
  );
  const steps = [() => reply(502), () => reply(503), () => reply(504), reject, () => reply(200, "", { status: "applied" })];
  const out = await withFetch(async () => steps.shift()(), () => pollResult(ID, "running"));
  assert.equal(out.status, "applied");
});
