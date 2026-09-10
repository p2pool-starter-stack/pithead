import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardSlice, clone, renderApp, UI } from '../harness.mjs';

// --- App shell / connection states -----------------------------------------------------

test('App without state shows the right connection message', () => {
    assert.match(renderApp({ state: null, connected: true }), /Connecting to the dashboard/);
    assert.match(renderApp({ state: null, connected: false }), /Cannot reach the dashboard/);
});

test('App always renders the theme switcher, even before the first load', () => {
    assert.match(renderApp(), /theme-switcher/);
    assert.match(renderApp({ state: null }), /theme-switcher/);
});

test('operational App shows a disconnected banner when not connected', () => {
    // The banner names the timestamp of the data on screen (#382) — the fixture's last_update.
    assert.match(renderApp({ connected: false }), /Disconnected — showing data from 00:00:00/);
    assert.doesNotMatch(renderApp({ connected: true }), /Disconnected — showing data from/);
});

// --- Header -----------------------------------------------------------------------------

test('Header renders the brand, server badges, version + update badges', () => {
    const html = renderApp();
    assert.match(html, /brand-name">Pithead/);
    assert.match(html, /P2POOL/); // a server-provided mode badge
    assert.match(html, /Tor-only egress/); // the #170 egress badge rides in the header
    assert.match(html, /dev build/); // version badge text
    assert.match(html, /New release v9\.9\.9 available/); // update badge (#224)
});

test('Header surfaces a High Usage badge only when a resource is hot', () => {
    assert.doesNotMatch(renderApp(), /High Usage/); // base fixture is all "ok"
    const s = clone();
    s.system.cpu.level = 'high';
    assert.match(renderApp({ state: s }), /High Usage/);
});

// --- Hero band + operational cards ------------------------------------------------------

test('operational App renders the hero band and the headline cards', () => {
    const html = renderApp();
    assert.match(html, /hero-band/);
    assert.match(html, /Workers Alive/);
    assert.match(html, /Overview/);
    assert.match(html, /My P2Pool Node Stats/);
    assert.match(html, /XvB Donation Stats/);
    assert.match(html, /Stack Topology & Egress/);
    // One casing everywhere (#659): the Overview card matches the hero KPI's lowercase "in".
    assert.match(html, /Share in Window/);
    assert.doesNotMatch(html, /Share In Window/);
});

test('toggle groups carry the ARIA affordances of the theme-switcher pattern (#657)', () => {
    // The vnode walker serializes boolean true as a bare attribute and drops false, so a bare
    // `aria-pressed` marks the pressed control (in the browser Preact writes true/false strings).
    const html = renderApp({ ui: { ...UI, range: '1w' } });
    // Range row: real buttons in a labelled group; the active preset is pressed and titled.
    assert.match(html, /aria-label="Chart range"/);
    assert.match(html, /class="btn-range active" aria-pressed title="Chart range: 1 Wk">1 Wk</);
    // View toggle: labelled group; the active view's button is pressed.
    assert.match(html, /aria-label="Dashboard view"/);
    assert.match(html, /class="btn-toggle active" aria-pressed title="[^"]+">Advanced</);
    // Topology mesh toggle explains itself without hovering the diagram.
    assert.match(html, /class="topo-toggle" title="Container-to-container links inside the stack"/);
});

test('chart range buttons include All, active on the default full-history view (#655)', () => {
    // Default UI state is range 'all' — without an All button no range reads as selected,
    // and after picking a preset there is no way back to full history.
    assert.match(renderApp(), /class="btn-range active"[^>]*>All</);
    const weekly = renderApp({ ui: { ...UI, range: '1w' } });
    assert.match(weekly, /class="btn-range active"[^>]*>1 Wk</);
    assert.doesNotMatch(weekly, /class="btn-range active"[^>]*>All</);
});

test('chart legend renders a toggle for every layer, including the marker datasets (#652)', () => {
    const html = renderApp();
    for (const label of ['P2Pool (routed)', 'XvB (routed)', 'Shares', 'Events', 'Raffle wins']) {
        assert.match(html, new RegExp(`legend-item[^>]*>.*?${label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}</button>`),
            `missing legend toggle: ${label}`);
    }
    // A hidden marker layer renders its button in the off state, like the line series do.
    const hidden = renderApp({ ui: { ...UI, series: { events: false } } });
    assert.match(hidden, /class="legend-item off"[^>]*title="Show Events"/);
    assert.match(hidden, /class="legend-item"[^>]*title="Hide Raffle wins"/);
});

test('operational App renders the remaining advanced cards', () => {
    const html = renderApp();
    assert.match(html, /Global P2Pool Stats/);
    assert.match(html, /XMR Network/);
    assert.match(html, /Tari Merge-Mining/);
    assert.match(html, /P2Pool Earnings \(estimated\)/);
});

// --- Progressive disclosure ("show more") on stat-grid cards ---------------------------
//
// Global P2Pool Stats, My P2Pool Node Stats and XMR Network share the MoreStats pattern
// (components.mjs): headline stats always show, the rest sits collapsed behind a real <button>
// until toggled. Several sibling cards reuse the same labels (Overview and My P2Pool Node Stats
// both have a "Mining Mode" stat, for instance), so `cardSlice` scopes assertions to one card's
// own markup — from its id up to the next card's id — rather than matching against the whole page.
test('Global P2Pool Stats collapses to the headline stats by default (progressive disclosure)', () => {
    const card = cardSlice(renderApp(), 'card-global');
    // Headline: the pool's own money/health figures.
    assert.match(card, /Pool Hashrate/);
    assert.match(card, /Blocks Found/);
    assert.match(card, /<h5>Last Block<\/h5>/);
    // Detail (sidechain internals, peers, uptime, ...) stays out of the DOM until expanded.
    assert.doesNotMatch(card, /Sidechain Height/);
    assert.doesNotMatch(card, /PPLNS Window/);
    assert.doesNotMatch(card, /PPLNS Weight/);
    assert.doesNotMatch(card, /<h5>Uptime<\/h5>/);
    assert.match(card, /class="more-stats-toggle" aria-expanded="false"/);
    assert.match(card, /Show all \(12\)/);
});

test('My P2Pool Node Stats collapses to the headline stats by default', () => {
    const card = cardSlice(renderApp(), 'card-mynode');
    assert.match(card, /Total Hashrate/);
    assert.match(card, /P2Pool 1h Avg/);
    assert.match(card, /P2Pool 24h Avg/);
    assert.match(card, /Shares \(OK\/Err\)/);
    assert.doesNotMatch(card, /Stratum \(15m/);
    assert.doesNotMatch(card, /Connections/);
    assert.doesNotMatch(card, /Effort/);
    assert.doesNotMatch(card, /Reward Share/);
    assert.doesNotMatch(card, /Total Shares/);
    assert.match(card, /class="more-stats-toggle" aria-expanded="false"/);
    assert.match(card, /Show all \(12\)/);
});

test('XMR Network collapses to the headline stats by default', () => {
    const card = cardSlice(renderApp(), 'card-network');
    assert.match(card, /Block Height/);
    assert.match(card, /Difficulty/);
    assert.match(card, /Reward/);
    assert.doesNotMatch(card, /Node Mode/);
    assert.doesNotMatch(card, /DB Size/);
    assert.doesNotMatch(card, /Current Block Hash/);
    assert.doesNotMatch(card, /Network Time/);
    assert.match(card, /class="more-stats-toggle" aria-expanded="false"/);
    assert.match(card, /Show all \(8\)/); // 7 + the node's local/remote location (#1040)
});

test('MoreStats expands to show every stat when toggled, and persists the choice per card, independently of siblings', () => {
    // There is no localStorage under node --test (see logic.test.mjs's loadPref/savePref test) —
    // stub a minimal one so MoreStats's loadPref/savePref calls (the same helpers
    // dashboardEarningsTab already uses) have somewhere to read from, exactly as a real browser
    // would provide. Only dashboardCardNetwork is pre-seeded "expanded"; dashboardCardGlobal is
    // absent, so it must still fall back to collapsed — expansion is per-card, not global.
    const store = new Map([['dashboardCardNetwork', 'expanded']]);
    globalThis.localStorage = {
        getItem: (k) => (store.has(k) ? store.get(k) : null),
        setItem: (k, v) => store.set(k, String(v)),
    };
    try {
        const html = renderApp();
        const network = cardSlice(html, 'card-network');
        assert.match(network, /Node Mode/); // detail now visible
        assert.match(network, /Current Block Hash/);
        assert.match(network, /class="more-stats-toggle" aria-expanded="true"/);
        assert.match(network, /Show less/);
        const global = cardSlice(html, 'card-global');
        assert.doesNotMatch(global, /Sidechain Height/);
        assert.match(global, /class="more-stats-toggle" aria-expanded="false"/);
        assert.match(global, /Show all \(12\)/);
    } finally {
        delete globalThis.localStorage;
    }
});

test('Simple view shows the calculators hint until dismissed, never elsewhere (#425)', () => {
    // Fresh browser on the default Simple view: the pointer to the Advanced-only calculators shows.
    const simple = renderApp({ ui: { ...UI, view: 'simple', hintDismissed: false } });
    assert.match(simple, /advanced-hint/);
    assert.match(simple, /earnings estimates or the XvB tier calculator/);
    assert.match(simple, /Advanced view/);
    // Dismissed (dashboard.js persists it): gone from Simple view.
    const dismissed = renderApp({ ui: { ...UI, view: 'simple', hintDismissed: true } });
    assert.doesNotMatch(dismissed, /advanced-hint/);
    // Never shown outside Simple view — Advanced already has the calculators on screen.
    const advanced = renderApp({ ui: { ...UI, view: 'advanced', hintDismissed: false } });
    assert.doesNotMatch(advanced, /advanced-hint/);
    const config = renderApp({ ui: { ...UI, view: 'config', hintDismissed: false } });
    assert.doesNotMatch(config, /advanced-hint/);
});
