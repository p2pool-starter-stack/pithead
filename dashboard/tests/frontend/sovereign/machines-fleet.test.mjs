import assert from "node:assert/strict";
import { test } from "node:test";
import { FleetUpgrade } from "../../../mining_dashboard/web/static/sovereign/machines-fleet.mjs";
import { fleetControl, runView } from "../../../mining_dashboard/web/static/sovereign/machines-fleet-model.mjs";
import { MachinesPage } from "../../../mining_dashboard/web/static/sovereign/machines.mjs";
import { rigFleet } from "../fixtures/rigs.mjs";
import { render, renderToString } from "../helpers/render.mjs";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";

const plan = {
  version: "v1.15.0",
  eligible: [{ name: "rig-a", running: "v1.14.0" }, { name: "rig-b", running: "v1.13.0" }],
  skipped: [{ name: "rig-c", reason: "control API unreachable" }],
};

class Seeded extends FleetUpgrade {
  constructor(props) {
    super(props);
    Object.assign(this.state, props.seed);
  }
  setState(next) {
    Object.assign(this.state, typeof next === "function" ? next(this.state) : next);
  }
}
const show = (seed, props = {}) =>
  renderToString(html`<${Seeded} controlEnabled=${true} writable=${true} seed=${seed} ...${props} />`);

test("the control shows only with the editor on, a session and a rig behind, and names the target", () => {
  const base = { controlEnabled: true, writable: true, plan, run: null };
  assert.equal(fleetControl(base), true);
  assert.equal(fleetControl({ ...base, controlEnabled: false }), false);
  assert.equal(fleetControl({ ...base, writable: false }), false);
  assert.equal(fleetControl({ ...base, plan: { ...plan, eligible: [] } }), false);
  assert.equal(fleetControl({ ...base, plan: { version: null, eligible: plan.eligible } }), false);
  assert.equal(fleetControl({ ...base, plan: null }), false);
  assert.equal(fleetControl({ ...base, run: { status: "running" } }), false);
  assert.equal(fleetControl({ ...base, run: { status: "completed" } }), true);
  assert.match(show({ plan }), /<button type="button">Update all rigs to v1.15.0<\/button>/);
  assert.doesNotMatch(show({ plan: { ...plan, eligible: [] } }), /Update all rigs to/);
  assert.doesNotMatch(show({ plan }, { controlEnabled: false }), /Update all rigs to/);
  assert.doesNotMatch(show({ plan: null }), /Update all rigs to/);
});

test("the review dialog lists the rigs to upgrade and the rigs that cannot, with the reason", () => {
  const out = show({ plan, open: true });
  assert.match(out, /Will be upgraded.*rig-a: v1.14.0 to v1.15.0.*rig-b: v1.13.0 to v1.15.0/s);
  assert.match(out, /Cannot be upgraded.*rig-c: control API unreachable/s);
  assert.match(out, /Start update/);
  const none = show({ plan: { ...plan, skipped: [] }, open: true });
  assert.doesNotMatch(none, /Cannot be upgraded/);
});

test("progress shows each rig's settled outcome, never accepted as done, and no-op or throttled as not failed", () => {
  const run = {
    status: "running",
    version: "v1.15.0",
    rigs: [
      { name: "a", status: "applied" },
      { name: "b", status: "accepted" },
      { name: "c", status: "noop" },
      { name: "d", status: "throttled", reason: "inside the throttle window" },
      { name: "e", status: "rolled_back", reason: "build did not come back" },
      { name: "f", status: "failed", reason: "unreachable" },
      { name: "g", status: "running" },
      { name: "h", status: "pending" },
    ],
  };
  const view = runView(run);
  const word = Object.fromEntries(view.rigs.map((rig) => [rig.name, rig.word]));
  assert.equal(word.a, "Upgraded");
  assert.equal(word.b, "Requested, not confirmed done");
  assert.doesNotMatch(word.b, /^(Upgraded|Done)/);
  assert.equal(word.c, "Already current");
  assert.equal(word.d, "Retry later");
  assert.equal(word.e, "Rolled back");
  assert.equal(word.f, "Failed");
  assert.equal(view.headline, "Updating to v1.15.0: 6 of 8 rigs settled.");
  assert.equal(view.active, true);
  const out = show({ plan: null, run });
  assert.match(out, /rig-note">inside the throttle window/);
  assert.doesNotMatch(out, /Update all rigs to/);
});

test("a settled, rejected or old run reads honestly, and a stale run is not shown", () => {
  assert.equal(
    runView({ status: "completed", version: "v1", ts: 1000, rigs: [{ name: "a", status: "failed" }] }, 1100).headline,
    "Update to v1 finished: 1 of 1 rigs settled.",
  );
  assert.match(runView({ status: "rejected", error: "cooldown", ts: 1000 }, 1100).headline, /rejected: cooldown/);
  assert.equal(runView({ status: "completed", ts: 1000, rigs: [] }, 1000 + 86401), null);
  assert.equal(runView({ status: "running", ts: 1, rigs: [] }, 999999).active, true);
  assert.equal(runView(null), null);
});

function fakeFetch(handlers) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url, init });
    return handlers(init.method || "GET");
  };
  return { calls, restore: () => (globalThis.fetch = original) };
}
const reply = (status, body, text) => ({ ok: status < 400, status, json: async () => body, text: async () => text ?? "" });

test("a reload finds a run in progress, and start posts only the reviewed version", async () => {
  const run = { status: "running", version: "v1.15.0", ts: Date.now() / 1000, rigs: [{ name: "rig-a", status: "running" }] };
  const net = fakeFetch(() => reply(200, { ...plan, run }));
  try {
    const fleet = new Seeded({ controlEnabled: true, writable: true, seed: {} });
    await fleet.refresh();
    clearTimeout(fleet.timer);
    assert.deepEqual(fleet.state.run, run);
    assert.equal(fleet.state.plan.version, "v1.15.0");
    assert.match(renderToString(fleet.render(fleet.props, fleet.state)), /Updating to v1.15.0/);
    fleet.gone = false;
    net.restore();
    const post = fakeFetch((method) => (method === "POST" ? reply(202, { id: "x", rigs: ["rig-a", "rig-b"] }) : reply(200, { ...plan, run })));
    fleet.state.open = true;
    await fleet.start();
    clearTimeout(fleet.timer);
    const sent = post.calls[0];
    assert.equal(sent.init.method, "POST");
    assert.equal(sent.init.headers["X-Pithead-Control"], "1");
    assert.deepEqual(JSON.parse(sent.init.body), { version: "v1.15.0" });
    assert.equal(fleet.state.open, false);
    assert.deepEqual(fleet.state.run.rigs, [{ name: "rig-a", status: "pending" }, { name: "rig-b", status: "pending" }]);
    post.restore();
  } finally {
    net.restore();
  }
});

test("a refused start keeps the reason visible and unmounting stops the poll", async () => {
  const net = fakeFetch((method) => (method === "POST" ? reply(409, {}, "An Update all run is already in progress.") : reply(200, { ...plan, run: null })));
  try {
    const fleet = new Seeded({ controlEnabled: true, writable: true, seed: { plan, open: true } });
    await fleet.start();
    clearTimeout(fleet.timer);
    assert.match(fleet.state.error, /already in progress/);
    assert.match(renderToString(fleet.render(fleet.props, fleet.state)), /role="alert">An Update all run is already in progress/);
    fleet.componentWillUnmount();
    fleet.timer = undefined;
    await fleet.refresh();
    assert.equal(fleet.timer, undefined);
  } finally {
    net.restore();
  }
});

test("the Machines page leaves the control to the plan: absent before it loads and with the editor off", () => {
  const state = { control_enabled: true, workers: rigFleet(4) };
  assert.doesNotMatch(render(MachinesPage, { state }), /Update all rigs to/);
  assert.doesNotMatch(render(MachinesPage, { state: { ...state, control_enabled: false } }), /Update all rigs/);
});
