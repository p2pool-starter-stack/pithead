import assert from "node:assert/strict";
import { test } from "node:test";
import { EarningsPage, priceAssumption } from "../../../mining_dashboard/web/static/sovereign/earnings.mjs";
import { EarningsControl, electricityError, earningsPreview } from "../../../mining_dashboard/web/static/sovereign/earnings-control.mjs";
import { payoutRows, trackingNotice, xvbLine } from "../../../mining_dashboard/web/static/sovereign/earnings-model.mjs";
import { render } from "../helpers/render.mjs";

const fixture = () => ({
  control_enabled: true, range: "all", tari: { active: true },
  payouts: { monero: [{ x: 2000, amount: 1234567890123 }], tari: [{ x: 3000, amount: 2500000 }] },
  earnings: { available: true, coeff_day: 100, p2pool_hr: 0.000001, tari_reward: 50,
    confirmed: { enabled: false }, tari_confirmed: { enabled: false } },
  earnings_summary: { xmr: { enabled: false, actual_30d: null, partial: true } },
  xvb_calc: { enabled: true }, hashrate: { total: "10 kH/s", xvb_routed_1h: "2 kH/s" },
  xvb_history: [{ x: 3000, donation_fraction: 0.2 }],
  energy: { xmr_price: 0, cost_per_kwh: 0.2, price_source: { live: false, feed: false } },
});
const page = (state, props = {}) => render(EarningsPage, { state, url: "https://example.test/ui-preview?page=earnings", ...props });

test("payouts preserve atomic units, descending dates, chain visibility and malformed input refusal", () => {
  const state = fixture();
  assert.deepEqual(payoutRows(state).map(({ unit, amount }) => [unit, amount]), [["XTM", 2.5], ["XMR", 1.234567890123]]);
  state.payouts.monero.push({ x: NaN, amount: 1 }, { x: 1, amount: -1 }, { x: 1e20, amount: 1 }, { x: 1, amount: Infinity });
  state.tari.active = false;
  assert.equal(payoutRows(state).length, 1);
  assert.doesNotMatch(page(state), /Tari solo|XTM|Tari:/);
  assert.match(page(state), /1.234567890123 XMR/);
});

test("unknown, missing, partial and unreachable tracking cannot read as zero earnings", () => {
  for (const summary of [undefined, { enabled: false }, { enabled: true }, { enabled: true, reachable: false }, { enabled: true, reachable: true, partial: { "30d": true } }]) {
    assert.match(trackingNotice(summary), /incomplete/);
    const state = fixture();
    state.earnings.confirmed = summary;
    state.payouts = {};
    const out = page(state);
    assert.match(out, /does not mean you earned nothing/);
    assert.match(out, /Advanced › Payout tracking/);
    assert.doesNotMatch(out, /0.000000000000 XMR/);
  }
});

test("returns stay withheld for arbitrary network rates, bad prices, disconnect and very low hashrate", () => {
  for (const price of [null, -1, NaN, Infinity, 0, 10000]) {
    const state = fixture();
    state.energy.xmr_price = price;
    const out = page(state, { connected: false });
    assert.match(out, /dynamic window support/);
    assert.match(out, /Expected per day<\/dt><dd>Unavailable/);
    assert.match(out, /Expected per month<\/dt><dd>Unavailable/);
    assert.match(out, /never a payout countdown/);
    assert.match(out, /net after power remains unavailable/);
    assert.match(out, /long-run average is not a daily payment/);
    assert.doesNotMatch(out, /NaN|Infinity|USD [0-9]|2160|what-if|About this estimate/);
  }
});

test("Earnings adds two controls with login, none read-only or disconnected, and stays within the app budget", () => {
  for (const platform of ["appliance", "diy-login", "diy-readonly"]) {
    const state = fixture();
    state.control_enabled = platform !== "diy-readonly";
    state.os_update = platform === "appliance" ? {} : null;
    const out = page(state);
    const count = (out.match(/<button/g) || []).length;
    assert.equal(count, state.control_enabled ? 2 : 0);
    assert.ok(count <= 10);
    assert.doesNotMatch(out, /xvb\.enabled|dashboard\.energy|type="number"|type="text"/);
    assert.equal((page(state, { connected: false }).match(/<button/g) || []).length, 0);
    assert.equal((page(state, { sessionExpired: true }).match(/<button/g) || []).length, 0);
  }
});

test("XvB and price source data distinguish off, unknown, stale and recorded provenance", () => {
  const state = fixture();
  assert.match(xvbLine(state, true), /20%/);
  assert.match(xvbLine(state, false), /unavailable or stale/);
  state.xvb_history.push({ x: 4000, donation_fraction: NaN });
  assert.match(xvbLine(state, true), /unavailable or stale/);
  state.xvb_calc.enabled = false;
  assert.match(xvbLine(state, true), /XvB off/);
  assert.match(xvbLine({}, true), /not reported/);
  assert.match(priceAssumption({ price_source: { live: true, age_sec: 8 } }), /8 seconds ago/);
  assert.match(priceAssumption({ price_source: { live: true, feed: true, age_sec: null } }), /age is unavailable/);
});

test("electricity rejects blanks, negatives and non-finite values but accepts an unset zero", () => {
  for (const raw of ["", " ", "-1", "NaN", "Infinity", "1e309", "oops"]) assert.ok(electricityError(raw));
  for (const raw of ["0", "0.12", "1e-2"]) assert.equal(electricityError(raw), null);
});

test("real host preview keys get plain labels while the transaction and effects remain intact", () => {
  const original = { id: "host-1", destructive: true, approval_required: true,
    changes: [{ flag: "CONFIRM", msg: "XMRvsBeast setting (XVB_ENABLED): false → true; restart affected services." },
      { flag: "INFO", msg: "Energy calculator settings (dashboard.energy) — electricity price / currency / XMR price updated." }],
    preview_values: [{ key: "dashboard.energy.cost_per_kwh", label: "dashboard.energy.cost_per_kwh", old: 0.1, new: 0.2 }] };
  const shown = earningsPreview(original);
  assert.match(shown.changes[0].msg, /Join the XvB bonus.*restart affected services/);
  assert.doesNotMatch(shown.changes.map((change) => change.msg).join(" "), /XVB_ENABLED|dashboard\.energy/);
  assert.equal(shown.preview_values[0].label, "Electricity price");
  assert.deepEqual({ ...shown, changes: original.changes, preview_values: original.preview_values }, original);
  assert.equal(original.preview_values[0].label, "dashboard.energy.cost_per_kwh");
});

test("scoped edits reuse host preview, preserve masked secrets and unknown keys, and commit only the preview ID", async () => {
  const original = globalThis.fetch;
  const requests = [];
  const cfg = { xvb: { enabled: false }, dashboard: { energy: { cost_per_kwh: 0.1 }, auth: { password: { __secret__: true } } }, future: { keep: [1, 2] }, _editable_keys: ["xvb.enabled", "dashboard.energy.cost_per_kwh"] };
  const editor = new EarningsControl({ kind: "electricity", enabled: true });
  editor.setState = (next) => Object.assign(editor.state, next);
  globalThis.fetch = async (url, options) => {
    requests.push({ url, options });
    return new Response(JSON.stringify(url === "/api/config" ? cfg : url.endsWith("preview") ? { id: "scoped-1", status: "previewed", destructive: true, changes: [{ msg: "Electricity price changes." }] } : { status: "applied" }));
  };
  try {
    await editor.load();
    editor.onFieldEdit({ key: "dashboard.energy.cost_per_kwh", type: "number" }, "0.25");
    await editor.save();
    const proposed = JSON.parse(requests[1].options.body).config;
    assert.deepEqual(proposed.future, cfg.future);
    assert.deepEqual(proposed.dashboard.auth, cfg.dashboard.auth);
    assert.equal(proposed.dashboard.energy.cost_per_kwh, 0.25);
    assert.equal(proposed.xvb.enabled, false);
    assert.equal(requests[1].options.headers["X-Pithead-Control"], "1");
    editor.state.confirmText = "APPLY";
    await editor.commit();
    assert.deepEqual(JSON.parse(requests[2].options.body), { id: "scoped-1", confirm: "APPLY" });
    assert.equal(editor.state.result.status, "applied");
    editor.props.enabled = false;
    await editor.save();
    await editor.commit();
    assert.equal(requests.length, 3);
  } finally { globalThis.fetch = original; }
});

test("the fleet donation line links to Machines and never reads unknown as off", () => {
  const state = { ...fixture(), xmrig_donation: { available: true, percent: 1, rigs: 3, donating: 2, unknown: 0 } };
  const out = page(state);
  assert.match(out, /XMRig developers: 1 % of hashrate on 2 of 3 rigs\. <a href="[^"]*page=machines[^"]*">Machines<\/a>/);
  assert.doesNotMatch(out, /page=machines[^"]*advanced/);
  assert.match(page({ ...fixture(), xmrig_donation: { available: false, rigs: 2, donating: 0, unknown: 2 } }), /combined share unavailable/);
});
