import assert from "node:assert/strict";
import { test } from "node:test";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { admission, createSyncHistory, estimate, needsSync } from "../../../mining_dashboard/web/static/sovereign/sync-model.mjs";
import { overviewContent, SyncView } from "../../../mining_dashboard/web/static/sovereign/sync-view.mjs";
import { renderToString } from "../helpers/render.mjs";

const reading = (at, current = 1000) => ({
  syncing: true, tari_gates_sync: false,
  sync: { monero: { state: "syncing", percent: current / 20, current, target: 2000, remaining: 2000 - current } },
  sync_status: { sampled_at: at, chains: { monero: { local: true, reachable: true, synced: false } }, mining: { held: true, released: false, workers_rejected: false, fail_closed: false } },
});

test("ETA needs recent measured progress, resets regression and target changes, and finishes at zero", () => {
  const history = createSyncHistory();
  for (const [at, current, expected] of [[100, 1000, null], [130, 1100, null], [160, 1200, 240], [190, 1200, null]]) {
    const state = reading(at, current);
    history.observe(state);
    assert.equal(history.eta("monero", state.sync.monero), expected);
  }
  let state = reading(220, 900);
  history.observe(state);
  assert.equal(history.eta("monero", state.sync.monero), null);
  state = reading(250, 1000);
  state.sync.monero.target = 3000;
  history.observe(state);
  assert.equal(history.eta("monero", state.sync.monero), null);
  assert.equal(estimate({ state: "done" }, []), 0);
  assert.equal(estimate({ current: 1, target: 0 }, []), null);
});

test("reloading retains a bounded sync snapshot and ETA, repeated or stale samples add no progress", () => {
  let saved;
  const storage = { getItem: () => saved, setItem: (_key, value) => { saved = value; } };
  const history = createSyncHistory(storage);
  for (const [at, current] of [[100, 1000], [130, 1100], [160, 1200]]) history.observe({ ...reading(at, current), wallet: "secret" });
  const restored = createSyncHistory(storage);
  assert.equal(restored.snapshot.sync.monero.current, 1200);
  assert.equal(restored.eta("monero", restored.snapshot.sync.monero), 240);
  assert.doesNotMatch(saved, /secret|wallet/);
  restored.observe(reading(160, 1200));
  assert.equal(restored.eta("monero", restored.snapshot.sync.monero), 240);
  restored.observe(reading(1000, 1500));
  assert.equal(restored.eta("monero", restored.snapshot.sync.monero), null);
  assert.equal(createSyncHistory({ getItem: () => "broken" }).snapshot, null);
});

test("first sync, regression, recovery and resumed mining switch only Overview, with no counted control", () => {
  const state = reading(100);
  for (const platform of ["appliance", "diy-login", "diy-readonly"]) {
    state.control_enabled = platform !== "diy-readonly";
    state.os_update = platform === "appliance" ? {} : null;
    let out = renderToString(html`<${SyncView} state=${state} connected=${true} now=${100} />`);
    assert.match(out, /Mining waiting for Monero/);
    assert.match(out, /Estimate unavailable/);
    assert.doesNotMatch(out, /Tari|<button|<input|<select/);
    assert.match(out, /1,000 \/ 2,000/);
    assert.match(out, /Required-service recreation<\/dt><dd>Unknown/);
  }
  state.sync_status.chains.monero.synced = true;
  state.sync_status.mining = { released: true, held: false, workers_rejected: true };
  state.syncing = false;
  assert.equal(needsSync(state), true);
  assert.match(admission(state), /recovery window.*re-admission/);
  state.sync_status.mining.workers_rejected = false;
  assert.equal(needsSync(state), false);
  assert.match(admission(state), /Mining admitted/);
  assert.equal(overviewContent({ page: "overview", state, renderPage: () => "operational" }), "operational");
  state.sync_status.chains.monero.health = { level: "red", reasons: ["No peers"] };
  assert.equal(needsSync(state), true);
  assert.equal(overviewContent({ page: "settings", state, renderPage: () => "settings" }), "settings");
});

test("remote required or optional Tari, RPC failure, stale age, unknown and zero remain distinct", () => {
  const state = reading(100, 0);
  state.sync.tari = { state: "loading" };
  state.sync_status.chains.tari = { local: false, node: "node.example:18142", reachable: false, synced: false, base_node_state: "HEADER_SYNC", initial_sync_achieved: false, error: "GetTipInfo probe failed", wait_seconds: 720, recovery_remaining: 30 };
  state.tari_gates_sync = true;
  state.profile = { name: "Performance" };
  let out = renderToString(html`<${SyncView} state=${state} connected=${false} now=${220} />`);
  for (const text of [/required Tari/, /0%/, /Progress unknown/, /Disconnected/, /Sample age: 2 min/, /HEADER_SYNC/, /not yet achieved/, /node.example:18142/, /GetTipInfo probe failed/, /12 min/, /Recovery window/, /Performance syncs faster/]) assert.match(out, text);
  state.tari_gates_sync = false;
  assert.match(admission(state), /optional Tari/);
  assert.equal(needsSync(null), false);
  assert.match(admission({}), /unknown/);
  state.sync_status.mining.fail_closed = true;
  assert.match(admission(state), /fail-closed/);
});


test("damaged cached sample history is ignored without breaking fresh polling", () => {
  const saved = JSON.stringify({ snapshot: reading(160, 1200), samples: { monero: [null, "bad", {}, { at: 100, current: "bad", target: 2000 }] } });
  const history = createSyncHistory({ getItem: () => saved, setItem: () => {} });
  history.observe(reading(190, 1300));
  assert.equal(history.eta("monero", history.snapshot.sync.monero), null);
  assert.doesNotThrow(() => needsSync({ sync_status: { chains: { monero: null } } }));
});


test("remote Monero reports current synchronization without inventing a lifetime initial-sync flag", () => {
  const state = reading(100);
  state.sync_status.chains.monero = { local: false, node: "monero.example:18081", reachable: true, synced: true, initial_sync_achieved: null };
  const out = renderToString(html`<${SyncView} state=${state} connected=${true} now=${100} />`);
  assert.match(out, /monero.example:18081/);
  assert.match(out, /Reported state: SYNCED/);
  assert.match(out, /Initial sync: Unknown — not reported by Monero/);
  assert.match(out, /Synchronization<\/dt><dd>Synced/);
});


test("remote Tari startup and migration remain reported states", () => {
  for (const initializing of ["starting", "migrating"]) {
    const state = reading(100);
    state.sync.tari = { state: "loading" };
    state.sync_status.chains.tari = { local: false, initializing, reachable: true, synced: false };
    const out = renderToString(html`<${SyncView} state=${state} connected=${true} now=${100} />`);
    assert.match(out, new RegExp(`Reported state: ${initializing}`));
  }
});


test("a reachable synced node with the real amber health contract explains peer regression", () => {
  const state = reading(100);
  state.syncing = false;
  state.sync_status.mining = { released: true, held: false, workers_rejected: false };
  state.sync_status.chains.monero = { reachable: true, synced: true, healthy: true, health: { level: "amber", reasons: ["0 peer connections for 10 min"] } };
  assert.equal(needsSync(state), true);
  const out = renderToString(html`<${SyncView} state=${state} connected=${true} now=${100} />`);
  assert.match(out, /Degraded · 0 peer connections for 10 min/);
  assert.match(out, /Stable reachability/);
});


test("an old done gauge cannot override the node's explicit unsynced verdict", () => {
  const state = reading(100);
  state.sync_status.chains.monero.synced = false;
  for (const target of [0, 2000]) {
    state.sync.monero = { state: "done", percent: 100, current: target, target };
    const out = renderToString(html`<${SyncView} state=${state} history=${{ eta: () => 0 }} connected=${true} now=${100} />`);
    assert.match(out, /Progress unknown · Estimate unavailable/);
    assert.match(out, /Not synced/);
    assert.doesNotMatch(out, /Sync complete/);
  }
});


test("synced required nodes with a host hold wait for services rather than another sync", () => {
  const state = reading(100);
  state.sync_status.chains.monero.synced = true;
  assert.match(admission(state), /Required nodes are synced.*start required services/);
  state.tari_gates_sync = true;
  state.sync_status.chains.tari = { reachable: true, synced: false };
  assert.match(admission(state), /Monero and required Tari to sync/);
  state.sync_status.chains.tari.synced = true;
  assert.match(admission(state), /Required nodes are synced.*admit mining/);
});
