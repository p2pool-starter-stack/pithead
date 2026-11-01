import assert from "node:assert/strict";
import { test } from "node:test";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { detailSnapshot } from "../../../mining_dashboard/web/static/workers/workerlogic.mjs";
import { DONATION_LEVELS, dailyCost, fleetLine, rigDonation, timeSentence } from "../../../mining_dashboard/web/static/sovereign/donation-model.mjs";
import { DonationControl } from "../../../mining_dashboard/web/static/sovereign/machines-donation.mjs";
import { RigInspector } from "../../../mining_dashboard/web/static/sovereign/machines-inspector.mjs";
import { renderToString } from "../helpers/render.mjs";

test("the time sentence and daily cost follow the owner's wording and rounding", () => {
  assert.deepEqual(DONATION_LEVELS, [0, 1, 2, 5]);
  assert.equal(timeSentence(1), "1 minute in every 100 minutes, roughly 15 minutes a day.");
  assert.equal(timeSentence(2), "2 minutes in every 100 minutes, roughly 29 minutes a day.");
  assert.equal(timeSentence(5), "5 minutes in every 100 minutes, roughly 72 minutes a day.");
  assert.equal(timeSentence(0), "Nothing is donated.");
  assert.equal(dailyCost(2, 1000, 0.0001), "0.00200000 XMR a day");
  assert.equal(dailyCost(0, 1000, 0.0001), "0.00000000 XMR a day");
  assert.equal(dailyCost(1, 1, 1e-9), "less than 0.00000001 XMR a day");
  for (const [hashrate, coeff] of [[0, 1], [NaN, 1], [100, 0], [100, undefined]]) assert.equal(dailyCost(1, hashrate, coeff), null);
});

test("the shown level is the one the miner reports, with a mismatch spelled out", () => {
  assert.equal(rigDonation({ donate_level: 0 }, { DONATION: 0 }).mismatch, null);
  assert.equal(rigDonation({ donate_level: 1 }, { DONATION: 1 }).text, "1 % reported by the miner");
  assert.equal(rigDonation({ donate_level: 1 }, { DONATION: 0 }).mismatch, "Configured 0 %, running 1 %: needs a RigForge update to lower.");
  assert.equal(rigDonation({ donate_level: 1 }, { DONATION: 2 }).mismatch, "Configured 2 %, running 1 %: applies after the miner restarts.");
  for (const worker of [{}, { donate_level: null }, { donate_level: "1" }, undefined]) {
    const unknown = rigDonation(worker, { DONATION: 0 });
    assert.equal(unknown.text, "Own donation: unknown");
    assert.equal(unknown.mismatch, null);
  }
  assert.equal(rigDonation({ donate_level: 1 }, null).configured, null);
});

test("the fleet line counts rigs and never turns unknown into off", () => {
  assert.equal(fleetLine({ available: true, percent: 1, rigs: 3, donating: 2, unknown: 0 }), "XMRig developers: 1 % of hashrate on 2 of 3 rigs.");
  assert.equal(fleetLine({ available: true, percent: 0, rigs: 2, donating: 0, unknown: 0 }), "XMRig developers: off on all 2 rigs.");
  const partial = fleetLine({ available: false, rigs: 3, donating: 1, unknown: 2 });
  assert.match(partial, /combined share unavailable.*2 of 3 rigs report no level.*usually 1 %/);
  assert.doesNotMatch(partial, /off on all/);
  assert.equal(fleetLine(undefined), "XMRig developers: no rigs reported.");
});

const detail = (extra = {}) => ({
  control_enabled: true, editable: true, ip: null, writable_keys: ["DONATION"], last_applied: {}, rig_config: { DONATION: 0 },
  rigforge: { version: "1.0.0" }, rigforge_update: null, hashrate_history: { hashrate: [] }, history: [], hashrate_by_config: [], ...extra,
});
class Ready extends RigInspector {
  constructor(props) {
    super(props);
    Object.assign(this.state, { phase: "ready", detail: props.detail, editText: JSON.stringify(detailSnapshot(props.detail), null, 2) });
  }
}
const inspect = (worker, extra = {}) =>
  renderToString(html`<${Ready} name="rig" writable=${true} shared=${1} worker=${worker} detail=${detail(extra)} />`);
const managed = { name: "rig", status: "online", h60: 100, adopted: true, donate_level: 0 };

test("a managed rig gets the control and every rig gets the read-only level", () => {
  const out = inspect(managed);
  assert.match(out, /Support the XMRig developers.*Off.*1 %.*2 %.*5 %/s);
  assert.match(out, /XMRig developers<\/dt><dd>0 % reported by the miner/);
  const mismatch = inspect({ ...managed, donate_level: 1 });
  assert.match(mismatch, /Configured 0 %, running 1 %: needs a RigForge update to lower/);
});

test("an unmanaged, stock or control-off rig shows its level read-only with no control", () => {
  const stock = inspect({ ...managed, adopted: false, donate_level: 1 }, { editable: false, rig_config: null });
  assert.match(stock, /XMRig developers<\/dt><dd>1 % reported by the miner/);
  assert.doesNotMatch(stock, /Support the XMRig developers|Review change/);
  const silent = inspect({ name: "rig", status: "online", adopted: false }, { editable: false, rig_config: null });
  assert.match(silent, /XMRig developers<\/dt><dd>Own donation: unknown/);
  assert.doesNotMatch(silent, /Support the XMRig developers/);
  assert.doesNotMatch(inspect(managed, { control_enabled: false }), /Support the XMRig developers/);
  assert.doesNotMatch(inspect(managed, { writable_keys: ["WORKER_NAME"] }), /Support the XMRig developers/);
  const shared = renderToString(html`<${Ready} name="rig" writable=${true} shared=${2} worker=${managed} detail=${detail()} />`);
  assert.doesNotMatch(shared, /Support the XMRig developers/);
  assert.doesNotMatch(renderToString(html`<${Ready} name="rig" writable=${true} shared=${2} worker=${{ ...managed, donate_level: 1 }} detail=${detail()} />`), /Configured 0 %/);
});

function control(props = {}) {
  const calls = [];
  const instance = new DonationControl({ name: "rig a", worker: managed, rigConfig: { DONATION: 0 }, earnings: { available: true, coeff_day: 0.001 }, canEdit: true, onDone: () => calls.push("done"), ...props });
  instance.setState = (next) => Object.assign(instance.state, typeof next === "function" ? next(instance.state) : next);
  instance.view = () => renderToString(instance.render(instance.props, instance.state));
  return { instance, calls };
}

test("the preview shows share, time and cost, and APPLY gates the write", async () => {
  const { instance, calls } = control();
  assert.match(instance.view(), /<button type="button" disabled>Review change/);
  instance.setState({ choice: 2, review: true });
  const review = instance.view();
  assert.match(review, /Donation: 2 % of this rig's hashrate goes to the XMRig developers/);
  assert.match(review, /2 minutes in every 100 minutes, roughly 29 minutes a day/);
  assert.match(review, /Estimated cost at this rig's current hashrate: 0.00200000 XMR a day/);
  assert.match(review, /<button type="button" disabled>Confirm/);
  instance.setState({ confirm: "APPLY" });
  assert.doesNotMatch(instance.view(), /<button type="button" disabled>Confirm/);
  const original = globalThis.fetch;
  const posted = [];
  globalThis.fetch = async (url, init) => {
    posted.push([url, JSON.parse(init.body)]);
    return { json: async () => ({ status: "applied" }) };
  };
  try {
    await instance.apply(2);
  } finally {
    globalThis.fetch = original;
  }
  assert.deepEqual(posted, [["/api/control/worker-apply", { worker: "rig a", changes: { DONATION: 2 } }]]);
  assert.equal(instance.state.result.status, "applied");
  assert.equal(instance.state.review, false);
  assert.deepEqual(calls, ["done"]);
});

test("a missing hashrate or network figure says the cost is unavailable and the current level is not re-applied", () => {
  const { instance } = control({ earnings: { available: false } });
  instance.setState({ choice: 1, review: true });
  assert.match(instance.view(), /Daily cost is unavailable/);
  const same = control();
  same.instance.setState({ choice: 0 });
  assert.match(same.instance.view(), /<button type="button" disabled>Review change/);
});
