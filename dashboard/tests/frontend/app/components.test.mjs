import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardSlice, clone, renderApp, UI } from '../harness.mjs';
import { renderToString } from '../helpers/render.mjs';
import { readyInstance } from '../workers/workerview-helpers.mjs';

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

test('the disconnected banner is a live region (#1859)', () => {
    assert.match(renderApp({ connected: false }), /class="disconnected-banner" role="status" aria-live="polite">/);
});

test('the hashrate chart canvas carries a text alternative (#1859)', () => {
    assert.match(renderApp(), /<canvas role="img" aria-label="Hashrate chart: [^"]+"/);
});

// --- Landmarks + heading order (#1859: axe landmark-one-main / region / heading-order) ---------

test('the App has exactly one header, one main and a labelled nav landmark', () => {
    const html = renderApp();
    assert.equal((html.match(/<header[\s>]/g) || []).length, 1);
    assert.equal((html.match(/<main[\s>]/g) || []).length, 1);
    assert.match(html, /<nav class="view-controls" aria-label="View">/);
});

const levelsOf = (html) => [...html.matchAll(/<h([1-6])(?=[\s>])/g)].map((m) => Number(m[1]));

function assertContiguous(html, label) {
    const levels = levelsOf(html);
    for (let i = 1; i < levels.length; i++) {
        assert.ok(
            levels[i] <= levels[i - 1] + 1,
            `${label}: heading jumped from h${levels[i - 1]} to h${levels[i]} at index ${i}`,
        );
    }
    return levels;
}

test('heading levels never skip on the way down, from h1 through every card (#1859)', () => {
    // axe's heading-order rule: a level may drop by any amount but must never jump UP by more
    // than one. The shallow fixture only reaches h1/h2, so the levels that actually regressed
    // (the h3s and h4s below a card title) need the deep states as well — an earnings-available
    // payload for the estimate subheads and the XvB tier block, and Worker Inspect's own dialog.
    const levels = assertContiguous(renderApp(), 'advanced view');
    assert.ok(levels.length > 10, 'expected many headings across the advanced view');
    assert.equal(levels[0], 1, 'the brand name must be the page h1');

    // Earnings available -> the estimate subheads and the XvB tier block with its per-tier rows.
    const earnings = clone();
    earnings.earnings.available = true;
    earnings.earnings.tari_available = true;
    const deep = assertContiguous(renderApp({ state: earnings }), 'earnings + XvB');
    assert.ok(deep.includes(3), 'the earnings/XvB state must reach h3');

    // Worker Inspect is a dialog the App only mounts on demand, so drive the component itself.
    const inspect = renderToString(readyInstance().render());
    const inspectLevels = assertContiguous(inspect, 'Worker Inspect');
    assert.ok(inspectLevels.includes(2) && inspectLevels.includes(3), 'dialog h2 then section h3s');

    // The levels the promotion created must actually be exercised, or the walk above proves
    // nothing about them: a tree of h1/h2 alone can never trip the rule. Both `.est-heading`
    // instances in xvbview.mjs were promoted from h4 to h3 (to match their `.est-heading`
    // siblings elsewhere, which were already h3) — that promotion removed the last h4 from the
    // app, so the walk must see h3 and must never see h4 again.
    const all = [...levels, ...deep, ...inspectLevels];
    assert.ok(all.filter((l) => l === 3).length > 0, 'no h3 rendered — the walk never saw one');
    assert.equal(all.filter((l) => l === 4).length, 0, 'an h4 regressed back in — every heading below a card title must be h3');
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

test('the theme switcher lives inside the header, not fixed over the page (#1860)', () => {
    // It used to render as a sibling of Header, position: fixed over the viewport (overlapping the
    // chart and the phone hint). It now mounts inside the header's own markup, right of the
    // version badges, so it scrolls with the page instead of floating over whatever is under it.
    const html = renderApp();
    const header = html.slice(html.indexOf('id="top-header"'), html.indexOf('id="hero-band"'));
    assert.match(header, /class="toggle-group theme-switcher"/);
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
    assert.match(card, /<p class="stat-label">Last Block<\/p>/);
    // Detail (sidechain internals, peers, uptime, ...) stays out of the DOM until expanded.
    assert.doesNotMatch(card, /Sidechain Height/);
    assert.doesNotMatch(card, /PPLNS Window/);
    assert.doesNotMatch(card, /PPLNS Weight/);
    assert.doesNotMatch(card, /<p class="stat-label">Uptime<\/p>/);
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
