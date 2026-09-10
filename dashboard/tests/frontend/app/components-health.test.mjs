import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clone, renderApp } from '../harness.mjs';

test('Tari status gates the ✔ on a live gRPC channel, never on active-but-dead (#278/#313)', () => {
    // The ✔ must mean the merge-mine channel is actually up. A dead channel that still reads "active"
    // must show status-warn and NO check — otherwise a TRANSIENT_FAILURE reads as healthy (#278/#313).
    const connected = clone();
    Object.assign(connected.tari, { connected: true, active: true, status: 'Merge mining' });
    const cHtml = renderApp({ state: connected });
    assert.match(cHtml, /status-ok">Merge mining/);
    assert.match(cHtml, /check-inline/); // connected -> the ✔ shows

    const deadButActive = clone();
    Object.assign(deadButActive.tari, { connected: false, active: true, status: 'Merge mining' });
    const dHtml = renderApp({ state: deadButActive });
    assert.match(dHtml, /status-warn">Merge mining/);
    assert.doesNotMatch(dHtml, /check-inline/); // active-but-dead -> NO ✔ (the invariant)
});

test('Sync gauge shows a ✔ for a done chain and a live percent while syncing', () => {
    const s = clone();
    s.syncing = true;
    s.sync.monero.state = 'syncing';
    s.sync.monero.percent = 42;
    assert.match(renderApp({ state: s }), /42%/); // syncing chain shows its percent
    s.sync.monero.state = 'done';
    assert.match(renderApp({ state: s }), /check-big/); // done chain shows the ✔, not a percent
});

// --- Component Health & Egress (#170) ---------------------------------------------------

test('ComponentHealth shows a Tor-only summary, the topology nodes, and the egress drawer', () => {
    const html = renderApp();
    assert.match(html, /Stack Topology & Egress/);
    assert.match(html, /🛡️/); // safe shield, not the warning triangle
    assert.match(html, /All egress via Tor/);
    assert.match(html, /External rigs/);
    assert.doesNotMatch(html, /Built-in miner/);
    assert.match(html, /monerod/);
    // ...and the per-component egress drawer lists each component.
    assert.match(html, /All connections \(per component\)/);
    assert.match(html, /xmrig-proxy/);
});

test('StackTopology marks live routes with marching ants, never a dashed edge', () => {
    const html = renderApp();
    // The fixture carries tor-routed edges -> at least one ants-marked path...
    assert.match(html, /class="topo-edge-ants"/);
    // ...but never on an edge whose dash pattern is already spoken for (internal mesh /
    // firewall-blocked), where the animation would fight the static dashes.
    assert.doesNotMatch(html, /class="topo-edge-ants"[^>]*stroke-dasharray="[^"]/);
});

test('ComponentHealth flips to a warning summary when the posture leaks', () => {
    const s = clone();
    s.topology.summary.level = 'warn';
    s.topology.summary.label = '2 clearnet egress path(s) exposing your IP';
    assert.match(renderApp({ state: s }), /⚠️/);
    assert.match(renderApp({ state: s }), /exposing your IP/);
    assert.match(renderApp({ state: s }), /egress-summary c-bad/);
});

test('ComponentHealth still renders the panel but omits the drawer when egress is absent', () => {
    const s = clone();
    s.egress = null;
    const html = renderApp({ state: s });
    assert.match(html, /Stack Topology & Egress/); // the map still renders
    assert.doesNotMatch(html, /All connections \(per component\)/); // no drawer
});

// --- Sync mode --------------------------------------------------------------------------

test('syncing App renders the sync gauges instead of the dashboard', () => {
    const s = clone();
    s.syncing = true;
    const html = renderApp({ state: s });
    assert.match(html, /synchronizing with the network/);
    assert.match(html, /Monero Sync/);
    assert.match(html, /Tari Sync/);
    assert.doesNotMatch(html, /Workers Alive/);
});
