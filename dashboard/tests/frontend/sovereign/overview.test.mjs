import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { renderToString } from "../helpers/render.mjs";
import { activityEntries, attention, combinedRate, destinations, overviewStatus, poolAdvice, backupEvidence, donationReadings } from "../../../mining_dashboard/web/static/sovereign/overview-model.mjs";
import { OverviewChart, zoomWindow } from "../../../mining_dashboard/web/static/sovereign/overview-chart.mjs";
import { Overview } from "../../../mining_dashboard/web/static/sovereign/overview.mjs";

const healthy = () => ({
  overview: { snapshot_ts: Date.now() / 1000, shares_found: 3, shares_failed: 0, effort: 42, hashrate_now: "1.5 kH/s", hashrate_24h: "1.2 kH/s", system_available: true, xvb_enabled: false, tari_enabled: false },
  backup_status: { state: "success", last_success_at: Date.now() / 1000 },
  monero: { health: { level: "green" } }, db_healthy: true, badges: [],
  hashrate: { total: "1.5 kH/s", mode_name: "P2Pool" },
  sync: { monero: { state: "done" }, tari: { state: "loading" } },
  workers: [{ name: "rig-a", status: "online", h60: 1500 }], chart: { p2pool: [], xvb: [] },
});

test("healthy, off, empty, stale and partial-fleet overview stay truthful on every platform", () => {
  for (const platform of ["appliance", "login", "readonly"]) {
    const state = healthy();
    state.control_enabled = platform !== "readonly";
    state.os_update = platform === "appliance" ? { verdict: { outcome: "updated", to: "2.1.0" } } : null;
    let out = renderToString(html`<${Overview} state=${state} connected=${true} range="24h" />`);
    assert.match(out, /Everything is running normally/);
    assert.match(out, /1 of 1 mining/);
    assert.match(out, /1.2 kH\/s/);
    assert.doesNotMatch(out, /Tari|Estimated earnings|mine.cart|Reset zoom|Show all|Show less/);
    assert.equal((out.match(/<select/g) || []).length, 1);
    assert.equal((out.match(/<button|<input/g) || []).length, 0);
    assert.equal((out.match(/<article/g) || []).length, 3);
    assert.equal(out.includes("Appliance OS"), platform === "appliance");
    state.workers.push({ name: "rig-b", status: "offline", h60: null });
    out = renderToString(html`<${Overview} state=${state} connected=${false} range="24h" />`);
    assert.match(out, /1 of 2 mining/);
    assert.match(out, /Disconnected/);
    assert.match(out, /last snapshot/);
  }
  assert.match(overviewStatus({}, true), /freshness is unavailable/);
  const state = healthy(); state.overview.snapshot_ts -= 300;
  assert.match(overviewStatus(state, true), /stale/);
  assert.match(overviewStatus(null, true), /Waiting/);
});

test("mixed conditions use the approved display order and stable worker ordering", () => {
  const state = healthy();
  state.workers = [{ name: "z", ip: "b", status: "offline" }, { name: "a", ip: "c", status: "offline" }, { name: "a", ip: "a", status: "offline" }];
  state.sync.monero.state = "syncing";
  state.profile = { name: "Privacy" }; state.overview.tor_health = "unhealthy";
  state.system = { disk: { level: "high" } }; state.update = { available: true };
  state.backup_status = { state: "unknown", last_success_at: null };
  state.badges = [{ text: "⚠ Payout wallet changed" }];
  state.overview.config_warnings = ["bad setting"];
  state.overview.shares_failed = 2; state.pool_tier_suggestion = { tier: "nano", hashrate_24h: 5000, provisional: true };
  const items = attention(state);
  assert.deepEqual(items.map((item) => item.kind), ["rig", "rig", "rig", "node", "tor", "disk", "update", "backup", "tamper", "config", "shares", "pool"]);
  assert.deepEqual(items.slice(0, 3).map((item) => item.text.split(":")[0]), ["a", "a", "z"]);
  for (const item of items) {
    const url = new URL(item.href, "https://example.test/ui-preview");
    assert.ok(url.searchParams.get("page")); assert.ok(url.searchParams.get("advanced"));
  }
  state.profile.name = "Performance";
  assert.equal(attention(state).some((item) => item.kind === "tor"), false);
});

test("chart preserves timestamp gaps and hides disabled donations instead of inventing zero readings", () => {
  const state = healthy();
  state.chart = { p2pool: [{ x: 1000, y: 80 }, { x: 2000, y: null }, { x: 4000, y: 90 }], xvb: [{ x: 1000, y: 20 }, { x: 2000, y: null }, { x: 4000, y: 10 }] };
  assert.deepEqual(combinedRate(state.chart), [{ x: 1000, y: 100 }, { x: 2000, y: null }, { x: 4000, y: 100 }]);
  assert.equal(destinations(state).some((part) => part.key === "xvb"), false);
  state.overview.xvb_enabled = true;
  state.chart = { p2pool: [{ x: 1000, y: 80 }, { x: 2000, y: 80 }], xvb: [{ x: 1000, y: 20 }, { x: 2000, y: 20 }] };
  state.donation = { available: true, enabled: true, percent: 2, status: "idle" };
  state.xmrig_donation = { available: true, percent: 1 };
  const parts = destinations(state);
  assert.deepEqual(parts.map((part) => part.key), ["p2pool", "xvb", "project", "xmrig"]);
  assert.ok(Math.abs(parts.reduce((sum, part) => sum + part.percent, 0) - 100) < 1e-8);
  assert.equal(parts[2].estimated, true);
  assert.equal(zoomWindow(100000, 200000).to - zoomWindow(100000, 200000).from, 60);
  assert.equal(zoomWindow(NaN, 200000), null);
});

test("activity sorts all sources, limits are caller-owned, and secret-bearing fields never reach display", () => {
  const rows = activityEntries({ chart: { payouts: [{ x: 400000 }] } },
    { entries: [{ ts: "1970-01-01T00:05:00Z", status: "applied", actor: "secret-user", keys: "PASSWORD=secret", detail: "secret" }] },
    { entries: [{ ts: 500, status: 200, user: "secret-user", uri: "/ui-preview?token=secret" }, { ts: 600, status: 200, user: "secret-user", uri: "/api/state?secret" }] });
  assert.deepEqual(rows.map((row) => row.ts), [500, 400, 300]);
  assert.doesNotMatch(JSON.stringify(rows), /secret|PASSWORD|token/);
  assert.match(rows[0].text, /not a session sign-in/);
  assert.deepEqual(activityEntries(null, null, null), []);
});

test("pool advice consumes only the producer field; absent and malformed differ from a quiet null", () => {
  assert.equal(poolAdvice({}).available, false);
  assert.deepEqual(poolAdvice({ pool_tier_suggestion: null }), { available: true, suggestion: null });
  for (const tier of ["nano", "mini", "main"]) {
    const state = healthy();
    state.pool_tier_suggestion = { tier, hashrate_24h: 12345, provisional: true };
    const before = structuredClone(state);
    const item = attention(state).find((entry) => entry.kind === "pool");
    assert.match(item.text, new RegExp(`review ${tier}`));
    assert.match(item.text, /24-hour.*12.35 kH\/s/);
    assert.match(item.text, /will not change automatically/);
    assert.equal(new URL(item.href, "https://example.test").searchParams.get("advanced"), "pool-and-rigs");
    assert.deepEqual(state, before);
  }
  for (const suggestion of [false, {}, { tier: "other", hashrate_24h: 10000, provisional: true }, { tier: "nano", hashrate_24h: NaN, provisional: true }])
    assert.equal(poolAdvice({ pool_tier_suggestion: suggestion }).available, false);
  const state = healthy(); state.pool_tier_suggestion = null;
  assert.equal(attention(state).some((entry) => entry.kind === "pool"), false);
});

test("backup success is positive durable evidence; missing or incomplete readings remain unknown", () => {
  for (const source of [undefined, null, { state: "unknown", last_success_at: null }, { state: "success" }, { state: "pending" }, { state: "success", last_success_at: -1 }]) {
    const state = healthy(); state.backup_status = source;
    assert.equal(backupEvidence(state).state, "unknown");
    const item = attention(state).find((entry) => entry.kind === "backup");
    assert.match(item.text, /history is unavailable/);
    assert.doesNotMatch(item.text, /No backup|never|No successful backup/);
    assert.equal(new URL(item.href, "https://example.test").searchParams.get("advanced"), "backup");
  }
  const state = healthy();
  assert.equal(backupEvidence(state).state, "success");
  assert.equal(attention(state).some((entry) => entry.kind === "backup"), false);
});

test("future snapshots and unknown health do not acquire a healthy status", () => {
  const state = healthy(); state.overview.snapshot_ts += 60;
  assert.match(overviewStatus(state, true), /freshness is unavailable or stale/);
  state.overview.snapshot_ts -= 60; state.monero.health.level = "unknown";
  const out = renderToString(html`<${Overview} state=${state} connected=${true} range="24h" />`);
  assert.match(out, /Health is not confirmed/);
  assert.doesNotMatch(out, /class="status-ok"/);
});

test("donation legends distinguish unavailable, off and reduced producer states", () => {
  assert.deepEqual(donationReadings({ donation: { available: false } }), { project: null, xmrig: null });
  assert.equal(donationReadings({ donation: { available: true, enabled: false, percent: 2 } }).project, 0);
  assert.equal(donationReadings({ donation: { available: true, enabled: true, status: "reduced", percent: 2, reduced_percent: 1 } }).project, 1);
  assert.equal(donationReadings({ xmrig_donation: { available: true, percent: NaN } }).xmrig, null);
  const state = healthy(); state.overview.xvb_enabled = true;
  state.chart = { p2pool: [{ x: 1000, y: 100 }, { x: 2000, y: 0 }, { x: 11000, y: 0 }], xvb: [{ x: 1000, y: 0 }, { x: 2000, y: 100 }, { x: 11000, y: 100 }] };
  const parts = destinations(state);
  assert.equal(parts[0].percent, 5);
  assert.equal(parts[1].percent, 95);
});


test("zoom bounds clamp pan and zoom-out to retained history and reset clears the plugin transform", () => {
  const bounds = { min: 100000, max: 500000 };
  assert.deepEqual(zoomWindow(200000, 300000, 100, 100, bounds), { from: 100, to: 500 });
  assert.deepEqual(zoomWindow(200000, 300000, 1, -100, bounds), { from: 100, to: 200 });
  assert.equal(zoomWindow(1, 2, 0, 0, bounds), null);
  const changes = []; let resets = 0;
  const props = { state: { overview: { history_window: { from: 100, to: 500 } } }, range: "24h", window: null, onWindow: (value) => changes.push(value) };
  const chart = new OverviewChart(props); chart.props = props;
  chart.chart = { scales: { x: { min: 200000, max: 300000 } }, resetZoom: () => { resets++; chart.gesture(); } };
  chart.key({ key: "Home", preventDefault() {} });
  assert.equal(resets, 1); assert.deepEqual(changes, [null]);
  chart.componentDidUpdate({ ...props, window: { from: 200, to: 300 } });
  assert.equal(resets, 2);
  chart.key({ key: "ArrowRight", preventDefault() {} });
  assert.deepEqual(changes.at(-1), { from: 225, to: 325 });
  assert.equal(chart.debounce, undefined);
});

test("unrepresentable event timestamps cannot crash activity rendering", () => {
  assert.deepEqual(activityEntries({ overview_activity: { entries: [{ ts: 1e100, text: "invalid" }] } }, null, null), []);
});


test("empty history bounds are a no-op for zoom keys and cannot be dereferenced", () => {
  assert.equal(zoomWindow(100000, 200000, 0.5, 0, null), null);
  const changes = [];
  const chart = new OverviewChart({});
  chart.props = { state: {}, onWindow: (value) => changes.push(value) };
  chart.chart = { scales: { x: { min: 100000, max: 200000 } } };
  chart.key({ key: "+", preventDefault() {} });
  assert.deepEqual(changes, []);
});

test("future or unrepresentable backup-success stamps remain unknown", () => {
  for (const stamp of [1e100, Date.now() / 1000 + 86400])
    assert.equal(backupEvidence({ backup_status: { state: "success", last_success_at: stamp } }).state, "unknown");
});

test("hidden chart axes resolve with the shipped Chart.js configuration", (t) => {
  const BundledChart = createRequire(import.meta.url)("../../../mining_dashboard/web/static/vendor/chart.umd.min.js");
  const original = globalThis.Chart;
  globalThis.Chart = BundledChart;
  t.mock.method(console, "error", () => {});
  const chart = new OverviewChart({});
  chart.props = { state: healthy() };
  chart.canvas = {};
  chart.colors = () => ({});
  try {
    chart.sync();
    assert.equal(chart.chart.config.options.scales.markers.axis, "y");
    assert.equal(chart.chart.config.options.scales.percent.axis, "y");
  } finally {
    chart.chart?.destroy();
    if (original === undefined) delete globalThis.Chart;
    else globalThis.Chart = original;
  }
});
