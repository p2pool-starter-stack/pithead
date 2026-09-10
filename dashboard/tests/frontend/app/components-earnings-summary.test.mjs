import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardSlice, clone, renderApp, UI } from '../harness.mjs';

// --- ExpectedVsActualCard (#808) -------------------------------------------------------

test('ExpectedVsActualCard renders in BOTH views and yields to nothing when empty (#808)', () => {
    // The base fixture has XvB on (one recorded win) → the card renders, Simple and Advanced.
    assert.match(renderApp({ ui: { ...UI, view: 'simple' } }), /card-expected-vs-actual/);
    assert.match(renderApp({ ui: { ...UI, view: 'advanced' } }), /card-expected-vs-actual/);
    // Nothing to compare on any stream → the card yields entirely (no empty shell).
    const s = clone();
    s.earnings_summary = {
        xmr: { available: false, enabled: false },
        tari: { available: false, enabled: false },
        xvb: { enabled: false },
    };
    assert.doesNotMatch(renderApp({ state: s }), /card-expected-vs-actual/);
    // A stale payload without the key (mid-upgrade poll) must not take the App down.
    delete s.earnings_summary;
    assert.match(renderApp({ state: s }), /Overview/);
});

test('ExpectedVsActualCard compares combined Monero+XvB with a percent and partial marks (#817)', () => {
    const s = clone();
    s.earnings_summary.xmr = {
        available: true, expected_30d: 0.0123, includes_xvb: true, enabled: true,
        actual_30d: 0.0101, partial: true, pct: 82,
    };
    const out = renderApp({ state: s });
    assert.match(out, /Monero \+ XvB \(30d\)/);    // combined label when the estimate is folded
    assert.match(out, /0\.012300 XMR/);            // expected, formatXmr precision
    assert.match(out, /0\.010100 XMR \(82%\) \*/); // actual + pct + the partial asterisk
    assert.match(out, /covers only the payout history on record/); // the footnote appears
    // The card never pans (#817): wrapping table, and the scroll wrapper must stay gone —
    // scoped to this card's own markup, since other cards legitimately keep est-scroll.
    assert.match(out, /eva-table/);
    assert.doesNotMatch(cardSlice(out, 'card-expected-vs-actual'), /est-scroll/);
    // Without a fresh published estimate the label honestly drops the "+ XvB".
    s.earnings_summary.xmr.includes_xvb = false;
    assert.match(renderApp({ state: s }), /Monero \(30d\)/);
});

test('ExpectedVsActualCard drops the percent when the server withholds it, tooltip explains (#992)', () => {
    // A near-zero expectation makes the server withhold pct (xvb_views.py caps at 999%) — the
    // actual figure stands alone and the row tooltip owns the missing percent.
    const s = clone();
    s.earnings_summary.xmr = {
        available: true, expected_30d: 1e-6, includes_xvb: false, enabled: true,
        actual_30d: 0.28, partial: false, pct: null,
        xvb_realization_pct: null, xvb_wins_measured: null,
    };
    const out = renderApp({ state: s });
    assert.match(out, /0\.280000 XMR/);
    assert.doesNotMatch(out, /0\.280000 XMR \(/); // no percent appended
    assert.match(out, /No percentage shown: the expected figure is near zero/);
    // A present percent keeps the old rendering and drops the explanation.
    s.earnings_summary.xmr.pct = 82;
    const withPct = renderApp({ state: s });
    assert.match(withPct, /\(82%\)/);
    assert.doesNotMatch(withPct, /No percentage shown/);
});

test('ExpectedVsActualCard shows the config key when confirmation is off, never a zero (#808)', () => {
    const s = clone();
    s.earnings_summary.xmr = { available: true, expected_30d: 0.0123, includes_xvb: false,
        enabled: false, actual_30d: null, partial: false, pct: null };
    s.earnings_summary.tari = { available: true, expected_blocks_30d: 0.0052, enabled: false,
        blocks_30d: null, xtm_30d: null, partial: false };
    const out = renderApp({ state: s });
    assert.match(out, /set monero\.view_key/);
    assert.match(out, /set tari\.view_key/);
    assert.doesNotMatch(out, /0\.000000 XMR \(/); // no zero-actual masquerading as a figure
    // Tari expectation keeps two significant digits — a fraction of a block must never read 0.0.
    assert.match(out, /≈ 0\.0052 blocks/);
});

test('ExpectedVsActualCard counts Tari blocks and windows XvB wins (#808)', () => {
    const s = clone();
    s.earnings_summary.tari = { available: true, expected_blocks_30d: 0.41, enabled: true,
        blocks_30d: 1, xtm_30d: 12345.0, partial: false };
    s.earnings_summary.xvb = { enabled: true, wins_30d: 2, last_win_ts: 1735689000 };
    const out = renderApp({ state: s });
    assert.match(out, /≈ 0\.41 blocks/);
    assert.match(out, /1 block · 12345\.0000 XTM/); // singular block, XTM alongside
    assert.match(out, /2 wins · last /);
    // Since #817 the wins row carries NO XMR figure — its value lives in the combined row.
    assert.doesNotMatch(out, /XMR\/day/);
    // XvB off → the row disappears (no invented raffle framing on a non-XvB box).
    s.earnings_summary.xvb = { enabled: false, wins_30d: 0, last_win_ts: 0 };
    assert.doesNotMatch(renderApp({ state: s }), /XvB wins \(30d\)/);
});

test('disabled XvB de-emphasizes: no stats card, no header split line, no hero raffle slots', () => {
    // One mention — the mode badge — is enough on a non-donating box. The stats card, the
    // header's routed-split line, and the two hero raffle KPIs all stand down with it.
    const s = clone();
    assert.match(renderApp({ state: s }), /XvB Donation Stats/); // fixture has XvB on
    assert.match(renderApp({ state: s }), /XvB \(routed\):/);
    s.xvb_calc = { enabled: false };
    const off = renderApp({ state: s });
    assert.doesNotMatch(off, /XvB Donation Stats/);
    assert.doesNotMatch(off, /XvB \(routed\):/);
    assert.doesNotMatch(off, /Raffle Eligible/);
    assert.doesNotMatch(off, /XvB Tier</);
});

test('raffle wins render inside the scroll-capped list wrapper', () => {
    // The wins log is what made the XvB card the tallest in its grid row (whitespace under every
    // neighbour) — the wrapper carries the max-height cap.
    assert.match(renderApp({ state: clone() }), /class="raffle-wins-list"/);
});

test('ExpectedVsActualCard forecasts XvB wins from the winners feed, dash when unmeasured (#866)', () => {
    const s = clone();
    s.earnings_summary.xvb = {
        enabled: true, wins_30d: 13, last_win_ts: 1735689000, expected_wins_30d: 25.2,
    };
    assert.match(renderApp({ state: s }), /≈ 25 wins/); // two significant digits
    // No aggregate (missing/stale) → the dash, never a guess.
    s.earnings_summary.xvb.expected_wins_30d = null;
    assert.doesNotMatch(renderApp({ state: s }), /≈ .* wins<\/td>/);
});

test('ExpectedVsActualCard tooltip owns the tempered vs face-value XvB share (#866)', () => {
    const s = clone();
    s.earnings_summary.xmr.includes_xvb = true;
    s.earnings_summary.xmr.xvb_realization_pct = 19;
    s.earnings_summary.xmr.xvb_wins_measured = 15;
    assert.match(renderApp({ state: s }), /19% of XvB(?:'|&#39;)s published face value/);
    s.earnings_summary.xmr.xvb_realization_pct = null;
    s.earnings_summary.xmr.xvb_wins_measured = null;
    assert.match(renderApp({ state: s }), /face-value estimate — an upper bound/);
});
