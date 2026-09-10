import { test } from 'node:test';
import assert from 'node:assert/strict';
import { computeXvbTier, xvbDecisionRows } from '../../../mining_dashboard/web/static/xvb/xvblogic.mjs';
import { formatXmr } from '../../../mining_dashboard/web/static/app/logic.mjs';

// --- computeXvbTier (#118) — transcription of resolve_target_threshold's auto rule ------

const XVB_CALC = {
    enabled: true,
    max_fraction: 0.85,
    tiers: [
        { name: 'Donor (1.00 kH/s+)', threshold: 1_000 },
        { name: 'Vip (10.00 kH/s+)', threshold: 10_000 },
        { name: 'Whale (100.00 kH/s+)', threshold: 100_000 },
        { name: 'Mega (1.00 MH/s+)', threshold: 1_000_000 },
    ],
};

// --- xvbDecisionRows (#872) — the per-tier decision table's pure math -------------------

const _CALC = {
    enabled: true, max_fraction: 0.85, realization_pct: null, realization_wins: null,
    tiers: [
        { name: 'Vip (10.00 kH/s+)', threshold: 10_000, expected_reward_year: 0.81,
          realized_reward_year: null, assumed_reward_year_range: [0.81 * 0.27, 0.81 * 0.38],
          win_odds_day: 0.12, players_avg: 31.4 },
        { name: 'Whale (100.00 kH/s+)', threshold: 100_000, expected_reward_year: 6.17,
          realized_reward_year: null, assumed_reward_year_range: [6.17 * 0.27, 6.17 * 0.38],
          win_odds_day: 0.84, players_avg: 8.2 },
    ],
};

test('computeXvbTier: pinned against the Python resolve_target_threshold auto case', () => {
    // Same inputs as tests/helper/test_utils.py::test_auto_picks_highest_sustainable:
    // 15,000 H/s × 0.85 = 12,750 sustains exactly the 10k (Vip) tier — the transcription
    // cross-check that keeps the JS and helper/utils.py rules from drifting silently.
    const t = computeXvbTier(15_000, XVB_CALC);
    assert.equal(t.threshold, 10_000);
    assert.equal(t.cost, 10_000);    // cost = the threshold itself (continuous donation)
    assert.match(t.tier, /Vip/);
});

test('computeXvbTier: below the lowest tier → null', () => {
    assert.equal(computeXvbTier(100, XVB_CALC), null);  // 100 × 0.85 = 85 < 1,000
});

test('computeXvbTier: exactly threshold / max_fraction clears the tier (boundary)', () => {
    assert.equal(computeXvbTier(10_000 / 0.85, XVB_CALC).threshold, 10_000);
});

test('computeXvbTier: between tiers picks the lower one', () => {
    // 60,000 × 0.85 = 51,000 — clears 10k, not 100k.
    assert.equal(computeXvbTier(60_000, XVB_CALC).threshold, 10_000);
});

test('computeXvbTier: null when calc missing, empty tiers, or bad hashrate', () => {
    assert.equal(computeXvbTier(15_000, null), null);
    assert.equal(computeXvbTier(15_000, { ...XVB_CALC, tiers: [] }), null);
    assert.equal(computeXvbTier(0, XVB_CALC), null);
    assert.equal(computeXvbTier(null, XVB_CALC), null);
});

test('computeXvbTier: still computes with XvB disabled — the what-if is the decision aid (#938)', () => {
    assert.equal(computeXvbTier(15_000, { ...XVB_CALC, enabled: false }).threshold, 10_000);
});

test('xvbDecisionRows: study band prices the measured delivery into the net verdict', () => {
    const rows = xvbDecisionRows(_CALC, 1e-7, 200_000); // whale cost 3.65, vip cost 0.365
    const whale = rows[1];
    assert.equal(whale.mode, 'study');
    assert.ok(Math.abs(whale.cost - 3.65) < 1e-9);
    assert.ok(Math.abs(whale.net[0] - (6.17 * 0.27 - 3.65)) < 1e-9);
    assert.ok(Math.abs(whale.net[1] - (6.17 * 0.38 - 3.65)) < 1e-9);
    assert.equal(whale.cls, 'status-bad'); // even the optimistic end loses
    assert.equal(whale.sustainable, true);
    assert.ok(Math.abs(whale.oddsPer30d - 25.2) < 1e-9);
});

test('xvbDecisionRows: a wallet\'s own measured wins supersede the study band', () => {
    const calc = structuredClone(_CALC);
    calc.realization_pct = 32; calc.realization_wins = 9;
    calc.tiers[1].realized_reward_year = 6.17 * 0.32;
    const whale = xvbDecisionRows(calc, 1e-7, 200_000)[1];
    assert.equal(whale.mode, 'yours');
    assert.ok(Math.abs(whale.net[0] - (6.17 * 0.32 - 3.65)) < 1e-9);
    assert.equal(whale.net[0], whale.net[1]); // a point, not a band
});

test('xvbDecisionRows: unsustainable tiers are flagged; face-only falls back labeled', () => {
    const rows = xvbDecisionRows(_CALC, 1e-7, 20_000); // whale needs 100k > 20k x 0.85
    assert.equal(rows[1].sustainable, false);
    assert.equal(rows[0].sustainable, true);
    // no band and no measured -> face-value mode, net still computed (component labels it)
    const calc = structuredClone(_CALC);
    calc.tiers[1].assumed_reward_year_range = null;
    const whale = xvbDecisionRows(calc, 1e-7, 200_000)[1];
    assert.equal(whale.mode, 'face');
    assert.ok(Math.abs(whale.net[0] - (6.17 - 3.65)) < 1e-9);
});

test('xvbDecisionRows: no coeff (network stats down) -> no cost, no net, never a guess', () => {
    const whale = xvbDecisionRows(_CALC, 0, 200_000)[1];
    assert.equal(whale.cost, null);
    assert.equal(whale.net, null);
    assert.equal(whale.mode, 'none');
    assert.equal(xvbDecisionRows(null, 1e-7, 200_000).length, 0);
});

test('xvbDecisionRows: XvB disabled still prices the table (#938)', () => {
    // The rows are the enable/don't-enable comparison, so the flag doesn't empty them —
    // a disabled payload with tiers prices identically to an enabled one.
    const rows = xvbDecisionRows({ ..._CALC, enabled: false }, 1e-7, 200_000);
    assert.equal(rows.length, 2);
    assert.ok(Math.abs(rows[1].cost - 3.65) < 1e-9);
});

// --- coinDp / net verdict (#1316) ---------------------------------------------------------

test('formatXmr: decimal places follow MAGNITUDE, so a loss is not longer than a gain (#1316)', () => {
    // coinDp compared the signed value, so every negative failed both `>= ` tests and fell
    // through to 8 dp: the Net column's losses carried four trailing zeros that said nothing,
    // and were always the widest string in their row.
    assert.equal(formatXmr(21.2706), '21.2706 XMR');
    assert.equal(formatXmr(-21.2706), '-21.2706 XMR');
    assert.equal(formatXmr(-1.3802), '-1.3802 XMR');
    assert.equal(formatXmr(-0.01858), '-0.018580 XMR');
    // A genuinely tiny magnitude still earns 8 dp — the fix is about sign, not about rounding
    // small figures away.
    assert.equal(formatXmr(-0.0000912), '-0.00009120 XMR');
    assert.equal(formatXmr(0.0000912), '0.00009120 XMR');
    // Mirror-image precision: a gain and the same-sized loss are the same length.
    assert.equal(formatXmr(-1.5).length, formatXmr(1.5).length + 1);
});

test('xvbDecisionRows: a band straddling zero is a WARN verdict, not uncoloured text (#1316)', () => {
    const calc = structuredClone(_CALC);
    // Vip: cost = 10000 x 1e-9 x 365 = 0.00365; band [0.003, 0.005] straddles it.
    calc.tiers[0].assumed_reward_year_range = [0.003, 0.005];
    const vip = xvbDecisionRows(calc, 1e-9, 200_000)[0];
    assert.ok(vip.net[0] < 0 && vip.net[1] > 0, 'band must straddle zero for this test to mean anything');
    assert.equal(vip.cls, 'status-warn');
    // The other two verdicts keep their existing meaning.
    calc.tiers[0].assumed_reward_year_range = [0.01, 0.02];
    assert.equal(xvbDecisionRows(calc, 1e-9, 200_000)[0].cls, 'status-ok');
    calc.tiers[0].assumed_reward_year_range = [0.0001, 0.0002];
    assert.equal(xvbDecisionRows(calc, 1e-9, 200_000)[0].cls, 'status-bad');
});

test('xvbDecisionRows: the face-value net is computed in its own right, not only as a fallback (#1316)', () => {
    // Study mode: `net` prices the study band, `netFace` prices XvB's published figure. The
    // reader had to subtract the Cost and XvB-says columns by eye to get this second number.
    const whale = xvbDecisionRows(_CALC, 1e-7, 200_000)[1]; // cost 3.65, face 6.17
    assert.equal(whale.mode, 'study');
    assert.ok(Math.abs(whale.netFace[0] - (6.17 - 3.65)) < 1e-9);
    assert.equal(whale.netFace[0], whale.netFace[1]); // a point, not a band
    assert.equal(whale.clsFace, 'status-ok'); // XvB's own figure profits...
    assert.equal(whale.cls, 'status-bad'); // ...while the measured study band does not
    // No cost (network stats down) means no face net either — never a guess.
    assert.equal(xvbDecisionRows(_CALC, 0, 200_000)[1].netFace, null);
    assert.equal(xvbDecisionRows(_CALC, 0, 200_000)[1].clsFace, '');
});
