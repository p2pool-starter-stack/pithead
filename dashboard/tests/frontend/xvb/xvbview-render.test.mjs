import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { App } from '../../../mining_dashboard/web/static/app/components.mjs';
import { render } from '../helpers/render.mjs';

// --- XvbTierBlock / XvbDecisionTable (rendered through the full App root) ----------------

const BASE = JSON.parse(readFileSync(new URL('../fixtures/state.json', import.meta.url)));

const clone = () => structuredClone(BASE);

// Default client UI state; the handlers are no-ops (the renderer never invokes them).
const UI = {
    view: 'advanced', range: 'all', window: null, series: {}, avg: '10m',
    theme: 'auto', sortIndex: null, sortAsc: true,
};

const noop = () => {};

const HANDLERS = {
    onRange: noop, onSort: noop, onView: noop, onTheme: noop,
    onZoom: noop, onResetZoom: noop, onToggleSeries: noop, onAvgWindow: noop,
    onDismissHint: noop, onInspect: noop, onCloseInspect: noop,
};

function renderApp({ state = BASE, connected = true, ui = UI } = {}) {
    return render(App, { state, connected, ui, ...HANDLERS });
}

test('XvB decision table: all tiers at once, study column, coloured net verdict (#872)', () => {
    const base = clone();
    base.earnings.available = true;
    base.earnings.coeff_day = 1e-7;
    base.earnings.p2pool_hr = 200000;
    base.earnings.p2pool_hr_str = '200.00 kH/s';
    base.xvb_calc = {
        enabled: true, max_fraction: 0.85, estimates_available: true, estimates_stale: false,
        current_tier: 'None', target_tier: 'Whale (100.00 kH/s+)', target_threshold: 100000,
        sustainable: true, note: 'An XvB tier is raffle status, not an XMR payout.',
        mode_note: null, realization_pct: null, realization_wins: null,
        tiers: [
            { name: 'Vip (10.00 kH/s+)', threshold: 10000, expected_reward_year: 0.81,
              realized_reward_year: null, assumed_reward_year_range: [0.81 * 0.27, 0.81 * 0.38],
              win_odds_day: 0.12, players_avg: 31.4 },
            { name: 'Whale (100.00 kH/s+)', threshold: 100000, expected_reward_year: 6.17,
              realized_reward_year: null, assumed_reward_year_range: [6.17 * 0.27, 6.17 * 0.38],
              win_odds_day: 0.84, players_avg: 8.2 },
            { name: 'Mega (1.00 MH/s+)', threshold: 1000000, expected_reward_year: 56.9,
              realized_reward_year: null, assumed_reward_year_range: [56.9 * 0.27, 56.9 * 0.38],
              win_odds_day: 9.4, players_avg: 1.0 },
        ],
    };
    const up = renderApp({ state: base });
    // One block per tier, no dropdown, every tier carrying odds, both estimates and a verdict.
    assert.match(up, /id="xvb-decision-tiers"/);
    assert.doesNotMatch(up, /id="xvb-tier-select"/);
    assert.match(up, /XvB says/);
    assert.match(up, /Study est\./);
    assert.match(up, /winners receiving 33% of face/);
    // Whale: cost 3.65; study band 1.6659…2.3446 collapses to its midpoint 2.0053, and the net
    // band (negative at both ends -> red) to -1.6447. Four dp, not eight: the negative no longer
    // falls through coinDp's magnitude test (#1316).
    assert.match(up, /2\.0053 XMR/);
    assert.match(up, /-1\.6447 XMR/);
    assert.doesNotMatch(up, /-1\.64470000/); // the old 8-dp negative
    // The band the midpoint came from is not lost — it moves into the cell's tooltip.
    assert.match(up, /Range: 1\.6659 XMR … 2\.3446 XMR/);
    // Both nets are named and answerable without subtracting two figures by eye.
    assert.match(up, /Net \(XvB says\)/);
    assert.match(up, /Net \(study\)/);
    // Mega is unsustainable at 200k×0.85: flagged, net withheld.
    assert.match(up, /Mega \(1\.00 MH\/s\+\) ⚠/);
    // Draw odds render per row.
    assert.match(up, /≈ 25 wins · 8\.2 players/);
    // XvB's face value stays visible as XvB's own number.
    assert.match(up, /6\.1700 XMR/);
});

test('XvB decision table: local measured wins supersede the study column (#872)', () => {
    const base = clone();
    base.earnings.available = true;
    base.earnings.coeff_day = 1e-7;
    base.earnings.p2pool_hr = 200000;
    base.earnings.p2pool_hr_str = '200.00 kH/s';
    base.xvb_calc = {
        enabled: true, max_fraction: 0.85, estimates_available: true, estimates_stale: false,
        current_tier: 'Whale (100.00 kH/s+)', target_tier: 'Whale (100.00 kH/s+)',
        target_threshold: 100000, sustainable: true, note: 'raffle status', mode_note: null,
        realization_pct: 32, realization_wins: 9,
        tiers: [
            { name: 'Whale (100.00 kH/s+)', threshold: 100000, expected_reward_year: 6.17,
              realized_reward_year: 6.17 * 0.32, assumed_reward_year_range: null,
              win_odds_day: 0.84, players_avg: 8.2 },
        ],
    };
    const up = renderApp({ state: base });
    assert.match(up, /Yours \(32% × 9 wins\)/);
    assert.match(up, /1\.9744[0-9]* XMR/); // 6.17 × 0.32
    assert.match(up, /-1\.6756[0-9]* XMR/); // net = 1.9744 − 3.65, single point
});

test('XvB decision table: verdict colours cover green and zero-spanning bands, stale degrades honestly (#872)', () => {
    const base = clone();
    base.earnings.available = true;
    base.earnings.coeff_day = 1e-9; // tiny cost so a positive band is constructible
    base.earnings.p2pool_hr = 200000;
    base.earnings.p2pool_hr_str = '200.00 kH/s';
    base.xvb_calc = {
        enabled: true, max_fraction: 0.85, estimates_available: true, estimates_stale: false,
        current_tier: 'None', target_tier: 'Vip (10.00 kH/s+)', target_threshold: 10000,
        sustainable: true, note: 'raffle status', mode_note: null,
        realization_pct: null, realization_wins: null,
        tiers: [
            // cost = 10000 × 1e-9 × 365 = 0.00365; band well above -> green at both ends
            { name: 'Vip (10.00 kH/s+)', threshold: 10000, expected_reward_year: 0.81,
              realized_reward_year: null, assumed_reward_year_range: [0.22, 0.31],
              win_odds_day: 0.12, players_avg: 31.4 },
            // band straddles cost -> neutral (no class)
            { name: 'Whale (100.00 kH/s+)', threshold: 100000, expected_reward_year: 6.17,
              realized_reward_year: null, assumed_reward_year_range: [0.03, 0.05],
              win_odds_day: 0.84, players_avg: 8.2 },
        ],
    };
    const up = renderApp({ state: base });
    // Green: even the pessimistic end profits. Band [0.21635, 0.30635] -> midpoint 0.261350.
    assert.match(up, /class="status-ok">0\.261350 XMR/);
    // Zero-spanning band [-0.0065, 0.0135] -> midpoint 0.003500, and an explicit WARN class.
    // It used to render as plain uncoloured text, indistinguishable from a cell carrying no
    // verdict at all (#1316); "could go either way" is a verdict and now says so.
    assert.match(up, /class="status-warn">0\.003500 XMR/);
    assert.doesNotMatch(up, /class="">0\.003500 XMR/);
    // Stale estimates: costs still render, estimate/net columns dash, footer says costs only.
    const stale = clone();
    stale.earnings.available = true;
    stale.earnings.coeff_day = 1e-7;
    stale.earnings.p2pool_hr = 200000;
    stale.xvb_calc = { ...base.xvb_calc, estimates_available: false, estimates_stale: true,
        tiers: base.xvb_calc.tiers.map((t) => ({ ...t, expected_reward_year: null,
            assumed_reward_year_range: null, realized_reward_year: null })) };
    const sh = renderApp({ state: stale });
    assert.match(sh, /tier costs only/);
    assert.match(sh, /0\.365\d* XMR/); // vip cost at 1e-7
});

test('XvB decision table: the vendored-fallback reward columns render values and say so, not the bare "tier costs only" footer (#1214)', () => {
    // #1214: with XvB disabled and never enabled (no live cache), the server fills the reward
    // columns from its published-table fallback and labels it estimates_source: 'published'
    // plus a date. The table must show real figures (not dashes) and the footer must say the
    // numbers are the last-published table, not a live fetch — never the old bare "tier costs
    // only" wording, which reads as "we have no idea" when the real answer is available.
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-9;
    s.earnings.p2pool_hr = 200000;
    // expected_reward_year/assumed_reward_year_range mirror what build_xvb_calc's corrected
    // fallback (views.XVB_PUBLISHED_REWARD_FALLBACK["donor_vip"] = 0.81, the archived file's
    // PER-PLAYER row, not the much larger pool-total row) would actually emit for a disabled box.
    s.xvb_calc = {
        enabled: false, max_fraction: 0.85, estimates_available: false, estimates_stale: false,
        estimates_source: 'published', estimates_published_date: '2026-08-10',
        current_tier: 'Disabled', target_tier: 'Disabled', target_threshold: 10000,
        sustainable: true, note: 'raffle status', mode_note: null,
        realization_pct: null, realization_wins: null,
        tiers: [
            { name: 'Vip (10.00 kH/s+)', threshold: 10000, expected_reward_year: 0.81,
              realized_reward_year: null, assumed_reward_year_range: [0.81 * 0.28, 0.81 * 0.39],
              win_odds_day: null, players_avg: null },
        ],
    };
    const up = renderApp({ state: s });
    // XvB says and Study est. are no longer dashed.
    assert.match(up, /0\.810000 XMR/); // "XvB says", face value straight from the fallback
    // Study est. = fallback face × the SAME prior, shown as the band's midpoint with the band
    // itself kept in the tooltip (#1316).
    assert.match(up, /0\.271350 XMR/);
    assert.match(up, /Range: 0\.226800 XMR … 0\.315900 XMR/);
    assert.doesNotMatch(up, /tier costs only/);
    assert.match(up, /last published table \(2026-08-10\)/);
    // Odds have no such fallback — same root cause; the cell names what it waits for (#1231).
    assert.match(up, /Odds \/ 30d needs XvB enabled/);
});

test('XvB decision block: in the operator\'s render state (XvB OFF) no figure is a sideways-panning range (#1316)', () => {
    // The state this issue was reported from, and the one a previous layout fix was NOT measured
    // in: XvB disabled, so build_xvb_calc falls back to the vendored published table, the odds
    // feed has nothing, and realization is never computed. Every tier priced, nothing live.
    const PRIOR = [0.28, 0.39];
    const FALLBACK = { donor: 0.064, donor_vip: 0.81, donor_whale: 4.67, donor_mega: 54.54 };
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-7;
    s.earnings.p2pool_hr = 200000;
    s.xvb_calc = {
        enabled: false, max_fraction: 0.85, estimates_available: false, estimates_stale: false,
        estimates_source: 'published', estimates_published_date: '2026-08-10',
        current_tier: 'Disabled', target_tier: 'Disabled', target_threshold: 0,
        sustainable: true, note: 'raffle status', mode_note: null,
        realization_pct: null, realization_wins: null,
        tiers: [
            ['Donor (1.00 kH/s+)', 1000, 'donor'], ['Vip (10.00 kH/s+)', 10000, 'donor_vip'],
            ['Whale (100.00 kH/s+)', 100000, 'donor_whale'], ['Mega (1.00 MH/s+)', 1000000, 'donor_mega'],
        ].map(([name, threshold, key]) => ({
            name, threshold, expected_reward_year: FALLBACK[key], realized_reward_year: null,
            assumed_reward_year_range: [FALLBACK[key] * PRIOR[0], FALLBACK[key] * PRIOR[1]],
            win_odds_day: null, players_avg: null,
        })),
    };
    const up = renderApp({ state: s });
    // Bound the slice to the decision block itself — the page has other cards with real tables.
    const from = up.indexOf('id="xvb-decision-tiers"');
    assert.ok(from > 0, 'the decision block must render with XvB off — it IS the enable/don\'t decision');
    const block = up.slice(from, up.indexOf('Reward figures are', from));
    assert.ok(block.length, 'block must end at the source footer');

    // Visible text only: tag-stripping also drops the title attributes the bands moved into.
    const visible = block.replace(/<[^>]*>/g, ' ');
    assert.doesNotMatch(visible, /…/, 'no visible figure may still be a low … high range');
    // The bands are preserved, just not at the cost of the card's width.
    assert.match(block, /title="[^"]*Range: [^"]*…[^"]*"/);

    // All four tiers, each with both named nets, and no panning table wrapper.
    for (const tier of ['Donor', 'Vip', 'Whale', 'Mega']) assert.ok(visible.includes(tier), tier);
    assert.equal(block.match(/Net \(XvB says\)/g).length, 4);
    assert.equal(block.match(/Net \(study\)/g).length, 4);
    assert.doesNotMatch(block, /table-scroll/);
    assert.doesNotMatch(block, /<table/);

    // Odds have no fallback while XvB is off; each tier names what it waits for (#1231).
    assert.equal(block.match(/Odds \/ 30d needs XvB enabled/g).length, 4);

    // Every visible XMR figure is a single number, and none of them is an 8-dp negative.
    const figures = visible.match(/-?\d+\.\d+ XMR/g) || [];
    assert.ok(figures.length >= 12, `expected a figure per net and input, got ${figures.length}`);
    assert.doesNotMatch(visible, /-\d+\.\d{8} XMR/);
});

test('XvB decision block: the fiat verdict line keeps the band it was collapsed from (#1316)', () => {
    // The one line that states the verdict in the operator's own currency is also a midpoint, and
    // it is the line most likely to be read alone. Every other collapsed figure in this block keeps
    // its range in a tooltip; this one lost it in the rewrite, which is a figure with no recovery
    // path rather than a spread moved one hover away.
    const base = clone();
    base.earnings.available = true;
    base.earnings.coeff_day = 1e-7;
    base.earnings.p2pool_hr = 200000;
    base.earnings.p2pool_hr_str = '200.00 kH/s';
    base.energy.xmr_price = 150;
    base.xvb_calc = {
        enabled: true, max_fraction: 0.85, estimates_available: true, estimates_stale: false,
        current_tier: 'None', target_tier: 'Vip (10.00 kH/s+)', target_threshold: 10000,
        sustainable: true, note: 'An XvB tier is raffle status, not an XMR payout.',
        mode_note: null, realization_pct: null, realization_wins: null,
        tiers: [
            { name: 'Vip (10.00 kH/s+)', threshold: 10000, expected_reward_year: 0.81,
              realized_reward_year: null, assumed_reward_year_range: [0.81 * 0.27, 0.81 * 0.38],
              win_odds_day: 0.12, players_avg: 31.4 },
        ],
    };
    const up = renderApp({ state: base });
    const line = up.match(/<p[^>]*id="xvb-fiat-line"[^>]*>/);
    assert.ok(line, 'the fiat verdict line should render when a price is known');
    // Not merely "has a title": the title must carry the RANGE. A title holding anything else
    // would satisfy a laxer assertion while the spread stayed gone.
    assert.match(line[0], /title="[^"]*Range: [^"]*…[^"]*"/);
});
