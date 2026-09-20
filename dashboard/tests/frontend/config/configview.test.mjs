import { test } from "node:test";
import assert from "node:assert/strict";
import { ConfigView } from "../../../mining_dashboard/web/static/config/configview.mjs";
import { editableCandidate } from "../../../mining_dashboard/web/static/config/configlogic.mjs";
import { renderToString } from "../helpers/render.mjs";

const ID = "11111111-1111-4111-8111-111111111111";

const okResult = (body) => ({ status: 200, ok: true, json: async () => body });

test("editableCandidate drops private and prototype-control keys but keeps secret sentinels", () => {
  const out = editableCandidate(JSON.parse('{"__proto__":{"polluted":true},"constructor":{"polluted":true},"network":{"mtu":1500},"secret":{"__secret__":true}}'));
  assert.equal(Object.getPrototypeOf(out), Object.prototype);
  assert.equal(Object.hasOwn(out, "constructor"), false);
  assert.equal(Object.prototype.polluted, undefined);
  assert.deepEqual(out.network, { mtu: 1500 });
  assert.deepEqual(out.secret, { __secret__: true });
});

// #1871: one card states the control-channel-off fact once, links the guide, and keeps the
// exact setting in a <code> aside; the host file path and ./pithead apply no longer appear as
// user text. htm drops whitespace at a text/<code> boundary split across a line break unless an
// explicit ${" "} holds it — the regression this guards is literal concatenation like
// "Setting:dashboard.control.enabled".
test("the disabled card states the fact once, links the guide, and keeps the key spaced from its label (#1871)", () => {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  Object.assign(view.state, { phase: "disabled" });
  const out = renderToString(view.render());
  assert.match(out, /docs\/dashboard\.md#configuration-view/);
  assert.match(out, /<code>dashboard\.control\.enabled<\/code>/);
  assert.doesNotMatch(out, /Setting:dashboard/);
  assert.doesNotMatch(out, /setdashboard/);
  assert.doesNotMatch(out, /truein/);
  assert.doesNotMatch(out, /pithead apply/);
  assert.doesNotMatch(out, /config\.json/);
});

test("carried SSH configuration is warned about and not proposed", async () => {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => okResult({ ssh: { enabled: true }, network: { mtu: 1500 } });
  try {
    await view.load();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(Object.hasOwn(view.buildProposed().config, "ssh"), false);
  assert.equal(view.state.sections.flatMap((section) => section.fields).some((field) => field.key.startsWith("ssh.")), false);
  const rendered = renderToString(view.render());
  assert.match(rendered, /SSH settings from an older configuration are ignored/);
  assert.doesNotMatch(rendered, /ssh\.enabled/);

  view.onJsonInput('{"ssh":{"authorized_key":"retired"},"network":{"mtu":1400}}');
  assert.equal(Object.hasOwn(view.buildProposed().config, "ssh"), false);
  assert.doesNotMatch(view.state.editText, /authorized_key/);
});

// Drive poll() with setTimeout fired synchronously so the 2s cadence doesn't slow the test,
// restoring the globals afterwards.
async function withFastPoll(fetchStub, fn) {
  const realFetch = globalThis.fetch;
  const realTimeout = globalThis.setTimeout;
  globalThis.fetch = fetchStub;
  globalThis.setTimeout = (cb) => {
    cb();
    return 0;
  };
  try {
    return await fn();
  } finally {
    globalThis.fetch = realFetch;
    globalThis.setTimeout = realTimeout;
  }
}

test("poll rides out a transient fetch failure (container recreate) then returns the result", async () => {
  let calls = 0;
  const fetchStub = async () => {
    calls++;
    if (calls === 1) throw new TypeError("Failed to fetch"); // dashboard restarting mid-apply
    return okResult({ status: "applied" });
  };
  const view = new ConfigView({});
  const out = await withFastPoll(fetchStub, () => view.poll(ID));
  assert.equal(out.status, "applied");
  assert.equal(calls, 2); // it retried after the throw instead of surfacing an error
});

test("poll skips the still-present preview result until the commit outcome lands", async () => {
  let calls = 0;
  const fetchStub = async () => {
    calls++;
    return okResult(calls < 2 ? { status: "previewed" } : { status: "applied" });
  };
  const view = new ConfigView({});
  const out = await withFastPoll(fetchStub, () => view.poll(ID, "previewed"));
  assert.equal(out.status, "applied");
});

test("commit polls its preview id after an empty successful response", async () => {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  view.state.preview = { id: ID, destructive: false };
  await withFastPoll(
    async (url) =>
      url === "/api/control/commit"
        ? { status: 202, ok: true, text: async () => "" }
        : okResult({ status: "applied" }),
    () => view.commit(),
  );
  assert.equal(view.state.phase, "done");
  assert.equal(view.state.result.status, "applied");
});

test("commit does not poll after a nonempty response without a result status", async () => {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  view.state.preview = { id: ID, destructive: false };
  let calls = 0;
  await withFastPoll(
    async () => {
      calls++;
      return { status: 202, ok: true, text: async () => "{}", json: async () => ({}) };
    },
    () => view.commit(),
  );
  assert.equal(calls, 1);
  assert.equal(view.state.phase, "error");
});

// #2366: the commit request itself recreates the dashboard container, so the browser's own
// fetch to /api/control/commit can be dropped mid-flight — the panel used to surface that as a
// raw `TypeError: Failed to fetch` instead of treating it as the expected restart.
test("commit falls back to polling its preview id when the commit request itself is dropped", async () => {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  view.state.preview = { id: ID, destructive: false };
  await withFastPoll(
    async (url) =>
      url === "/api/control/commit"
        ? Promise.reject(new TypeError("Failed to fetch"))
        : okResult({ status: "applied" }),
    () => view.commit(),
  );
  assert.equal(view.state.phase, "done");
  assert.equal(view.state.result.status, "applied");
});

// A 502/503/504 while the proxy is up but the app container is restarting is the same expected
// case, riding the same fallback rather than throwing HTTP 502 immediately.
test("commit falls back to polling its preview id on a 502/503/504 from the commit request", async () => {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  view.state.preview = { id: ID, destructive: false };
  await withFastPoll(
    async (url) =>
      url === "/api/control/commit"
        ? { status: 502, ok: false, text: async () => "" }
        : okResult({ status: "applied" }),
    () => view.commit(),
  );
  assert.equal(view.state.phase, "done");
  assert.equal(view.state.result.status, "applied");
});

// A real failure (4xx/5xx the proxy did not generate) still surfaces its message, not a raw
// browser error, and does not silently retry it as a restart.
test("commit surfaces a real HTTP error from the commit request instead of polling", async () => {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  view.state.preview = { id: ID, destructive: false };
  let calls = 0;
  await withFastPoll(
    async () => {
      calls++;
      return { status: 400, ok: false, text: async () => "bad request" };
    },
    () => view.commit(),
  );
  assert.equal(calls, 1);
  assert.equal(view.state.phase, "error");
  assert.match(view.state.error, /HTTP 400/);
});

test("a rejected appliance preview labels the host validation log", async () => {
  const view = new ConfigView({ appliance: true });
  view.props = { appliance: true };
  view.setState = (patch) => Object.assign(view.state, patch);
  Object.assign(view.state, { phase: "form", candidate: {}, cfg: {} });
  await withFastPoll(
    async () => okResult({ status: "rejected", log: "Run './pithead apply' after fixing p2pool.pool" }),
    () => view.save(),
  );
  const out = renderToString(view.render());
  assert.match(out, /Configuration preview did not complete/);
  assert.match(out, /this machine's own log from the\s+failed config preview/);
  assert.match(out, /\.\/pithead apply/);
  assert.match(out, /cannot\s+be run from here/);
});

test("a rejected appliance preview leaves an authored error unlabelled", async () => {
  const view = new ConfigView({ appliance: true });
  view.props = { appliance: true };
  view.setState = (patch) => Object.assign(view.state, patch);
  Object.assign(view.state, { phase: "form", candidate: {}, cfg: {} });
  await withFastPoll(
    async () => okResult({ status: "rejected", error: "Another config apply is already running" }),
    () => view.save(),
  );
  const out = renderToString(view.render());
  assert.match(out, /Another config apply is already running/);
  assert.doesNotMatch(out, /this machine's own log/);
});

// Minimal disruptive preview, only for the live-region assertions below — the modal's own
// rendering of a CONFIRM change is covered in configview-upgrade.test.mjs.
const CONFIRM_PREVIEW = {
  changes: [
    { flag: "CONFIRM", key: "monero.clearnet_initial_sync", msg: "Clearnet initial sync ENABLED — host IP exposed during IBD." },
  ],
  destructive: true,
};

// #1859 (the repo owner's cycle-4 addendum names this phase by string): entering the previewing
// phase only flipped the save button's own label, and the same `busy` flag disables that button —
// the phase change landed on an element that had just left the focus order, so a screen reader was
// told nothing. The remedy is a live region that is already in the DOM when the text arrives.
test("the previewing phase announces itself in a live region, not on the button it disables", async () => {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => okResult({ network: { mtu: 1500 } });
  try {
    await view.load();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(view.state.phase, "form");
  const EMPTY = /<p class="sr-only" role="status" aria-live="polite"><\/p>/;
  // Present and empty while the form is idle: a region inserted at the same moment as its text is
  // not reliably announced, so the element has to ship with the form.
  assert.match(renderToString(view.render()), EMPTY);

  Object.assign(view.state, { phase: "previewing" });
  const previewing = renderToString(view.render());
  assert.match(previewing, /<p class="sr-only" role="status" aria-live="polite">Previewing changes…<\/p>/);
  // The visible wording rides the button, which this phase disables — the region exists because
  // that button is what a screen-reader user can no longer reach.
  assert.match(previewing, /<button class="btn-toggle active" disabled>Previewing…<\/button>/);

  // Clears when the preview resolves (the modal the confirm phase opens needs a preview to draw).
  Object.assign(view.state, { phase: "confirm", preview: CONFIRM_PREVIEW });
  assert.match(renderToString(view.render()), EMPTY);
  // Keyed to the previewing phase, not to `busy`: `busy` also covers the commit, where this line
  // would otherwise claim a preview was running while the apply was.
  Object.assign(view.state, { phase: "committing" });
  assert.doesNotMatch(renderToString(view.render()), /Previewing changes…/);
});
