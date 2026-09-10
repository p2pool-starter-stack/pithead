import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heroKpis, raffleCls, bandBorderWidth, uptimeCell, egressRoute, boxAnchor } from '../../../mining_dashboard/web/static/app/logic.mjs';

// --- Issue #81: hero KPI band selector ------------------------------------------------

// Minimal /api/state shape carrying just the fields the band reads; `over` deep-overrides a
// section so each test changes only what it asserts on.
const _heroState = (over = {}) => ({
    hashrate: { total: '10.50 kH/s', tier: 'Donor (1.00 kH/s+)', mode_name: 'P2POOL',
                mode_variant: 'ok', ...over.hashrate },
    shares_window: { count: 5, ok: true, ...over.shares_window },
    raffle_eligible: { applies: true, eligible: true, label: 'Yes', ...over.raffle_eligible },
    pool: { blocks: 42, ...over.pool },
    xvb_calc: 'xvb_calc' in over ? over.xvb_calc : { enabled: true },
});

const _byLabel = (state) => Object.fromEntries(heroKpis(state).map((k) => [k.label, k]));

test('heroKpis: surfaces the six headline numbers under stable labels, in order', () => {
    assert.deepEqual(
        heroKpis(_heroState()).map((k) => k.label),
        ['Total Hashrate', 'Shares in Window', 'Raffle Eligible', 'Blocks Found', 'XvB Tier', 'Mining Mode'],
    );
});

test('heroKpis: the raffle slots vanish while XvB is disabled — no N/A dead weight', () => {
    // The mode badge says XvB is off, once; the band should not repeat it as two empty KPIs.
    assert.deepEqual(
        heroKpis(_heroState({ xvb_calc: { enabled: false } })).map((k) => k.label),
        ['Total Hashrate', 'Shares in Window', 'Blocks Found', 'Mining Mode'],
    );
    // A payload without the section at all (old server) behaves like disabled — never a crash.
    assert.deepEqual(
        heroKpis(_heroState({ xvb_calc: undefined })).map((k) => k.label),
        ['Total Hashrate', 'Shares in Window', 'Blocks Found', 'Mining Mode'],
    );
});

test('heroKpis: wires each KPI to its build_state field', () => {
    const k = _byLabel(_heroState());
    assert.equal(k['Total Hashrate'].value, '10.50 kH/s');   // hashrate.total
    assert.equal(k['Shares in Window'].value, 5);            // shares_window.count
    assert.equal(k['Raffle Eligible'].value, 'Yes');         // raffle_eligible.label
    assert.equal(k['Blocks Found'].value, 42);               // pool.blocks
    assert.equal(k['XvB Tier'].value, 'Donor (1.00 kH/s+)'); // hashrate.tier
    assert.equal(k['Mining Mode'].value, 'P2POOL');          // hashrate.mode_name
});

test('heroKpis: shares colour reflects the ok flag', () => {
    assert.equal(_byLabel(_heroState({ shares_window: { count: 3, ok: true } }))['Shares in Window'].cls, 'status-ok');
    assert.equal(_byLabel(_heroState({ shares_window: { count: 0, ok: false } }))['Shares in Window'].cls, 'status-bad');
});

test('heroKpis: Raffle Eligible colour reflects win eligibility (#158)', () => {
    assert.equal(_byLabel(_heroState({ raffle_eligible: { applies: true, eligible: true, label: 'Yes' } }))['Raffle Eligible'].cls, 'status-ok');
    assert.equal(_byLabel(_heroState({ raffle_eligible: { applies: true, eligible: false, label: 'No' } }))['Raffle Eligible'].cls, 'status-bad');
    // XvB off => N/A => muted (not red).
    assert.equal(_byLabel(_heroState({ raffle_eligible: { applies: false, label: 'N/A (XvB off)' } }))['Raffle Eligible'].cls, '');
});

test('raffleCls: muted when XvB off (N/A), green when eligible, red otherwise (#158)', () => {
    assert.equal(raffleCls({ applies: false, eligible: false }), '');   // N/A — XvB off
    assert.equal(raffleCls({ applies: true, eligible: true }), 'status-ok');
    assert.equal(raffleCls({ applies: true, eligible: false }), 'status-bad');
    assert.equal(raffleCls(undefined), '');                              // defensive: no state yet
});

test('heroKpis: mode colour follows the server mode_variant token', () => {
    // Same c-<token> mapping the Overview card uses, so the band's mode matches the rest of the UI.
    assert.equal(_byLabel(_heroState({ hashrate: { mode_variant: 'purple' } }))['Mining Mode'].cls, 'c-purple');
    assert.equal(_byLabel(_heroState({ hashrate: { mode_variant: 'accent' } }))['Mining Mode'].cls, 'c-accent');
});

test('heroKpis: total is accent-coloured; blocks and tier carry no colour class', () => {
    const k = _byLabel(_heroState());
    assert.equal(k['Total Hashrate'].cls, 'text-accent');
    assert.equal(k['Blocks Found'].cls, '');
    assert.equal(k['XvB Tier'].cls, '');
});

// #184: a flat-zero band must not paint its top border-line over the other series' edge.
test('bandBorderWidth: zero-height segments get no border, real ones keep full width', () => {
    // XvB off all window: every XvB sample is 0 → no purple line anywhere.
    const xvb = [{ x: 1, y: 0 }, { x: 2, y: 0 }, { x: 3, y: 0 }];
    assert.equal(bandBorderWidth(xvb, { p0DataIndex: 0, p1DataIndex: 1 }, 3.5), 0);
    assert.equal(bandBorderWidth(xvb, { p0DataIndex: 1, p1DataIndex: 2 }, 3.5), 0);
    // A series with real hashrate keeps its border on non-zero segments...
    const p2p = [{ x: 1, y: 0 }, { x: 2, y: 50 }, { x: 3, y: 80 }];
    assert.equal(bandBorderWidth(p2p, { p0DataIndex: 1, p1DataIndex: 2 }, 3.5), 3.5);
    // ...and drops it only where the band is genuinely flat-zero (one endpoint zero is enough to keep
    // the rising edge visible).
    assert.equal(bandBorderWidth(p2p, { p0DataIndex: 0, p1DataIndex: 1 }, 3.5), 3.5);
});

// #169: the Uptime cell must read DOWN for an offline worker, not a climbing duration.
test('uptimeCell: online shows uptime, offline shows DOWN', () => {
    assert.equal(uptimeCell({ status: 'online', uptime_str: '3h 20m' }), '3h 20m');
    assert.equal(uptimeCell({ status: 'offline', uptime_str: '99h 9m' }), 'DOWN');
});

// #170: egressRoute maps a server route token to a display glyph + label + CSS colour token.
test('egressRoute: known routes map to icon/label/class; unknown falls back to muted', () => {
    assert.deepEqual(egressRoute('tor'), { icon: '🧅', label: 'Tor', cls: 'ok' });
    assert.equal(egressRoute('clearnet').cls, 'bad');
    assert.equal(egressRoute('local').cls, 'muted');
    assert.equal(egressRoute('inactive').cls, 'muted');
    const unknown = egressRoute('weird');
    assert.equal(unknown.cls, 'muted');
    assert.equal(unknown.label, 'weird');
});

// #170: boxAnchor returns the point on a node box's border heading toward a target — for topology
// connectors that start/end flush on the box edge.
test('boxAnchor: lands on the border facing the target, not the centre', () => {
    const node = { x: 100, y: 100, w: 40, h: 20 }; // centre (120, 110)
    // Target straight to the right → exits the right edge (x = 140) at the centre height.
    assert.deepEqual(boxAnchor(node, 300, 110), { x: 140, y: 110 });
    // Target straight up → exits the top edge (y = 100) at the centre width.
    assert.deepEqual(boxAnchor(node, 120, 0), { x: 120, y: 100 });
    // Degenerate (target == centre) → the centre itself, no NaN.
    assert.deepEqual(boxAnchor(node, 120, 110), { x: 120, y: 110 });
});
