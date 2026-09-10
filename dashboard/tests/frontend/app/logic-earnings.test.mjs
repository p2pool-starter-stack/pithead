import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseHashrate, fmtHashrate, computeEarnings, formatXmr, formatXtm, formatTimeToShare, DAYS_PER_MONTH, DAYS_PER_YEAR } from '../../../mining_dashboard/web/static/app/logic.mjs';

// --- Issue #12: expected-earnings what-if --------------------------------------------

test('parseHashrate: accepts bare numbers and k/M/G suffixes', () => {
    assert.equal(parseHashrate('50000'), 50000);
    assert.equal(parseHashrate('10.5k'), 10500);
    assert.equal(parseHashrate('1.2M'), 1_200_000);
    assert.equal(parseHashrate('2.5g'), 2_500_000_000);
    // Round-trips the server's formatted measured-hashrate string (e.g. the input default).
    assert.equal(parseHashrate('10.50 kH/s'), 10500);
    assert.equal(parseHashrate('1.20 MH/s'), 1_200_000);
});

test('parseHashrate: rejects empty / unparseable input', () => {
    assert.equal(parseHashrate(''), null);
    assert.equal(parseHashrate('   '), null);
    assert.equal(parseHashrate('abc'), null);
    assert.equal(parseHashrate(null), null);
    assert.equal(parseHashrate(undefined), null);
});

test('fmtHashrate: mirrors the server format_hashrate unit boundaries (#387)', () => {
    // Same cases as tests/helper/test_utils.py TestFormatHashrate — the two must stay in lockstep.
    assert.equal(fmtHashrate(1_500_000_000), '1.50 GH/s');
    assert.equal(fmtHashrate(2_500_000), '2.50 MH/s');
    assert.equal(fmtHashrate(1_500), '1.50 kH/s');
    assert.equal(fmtHashrate(500), '500.00 H/s');
    assert.equal(fmtHashrate(0), '0.00 H/s');
    assert.equal(fmtHashrate('invalid'), '0 H/s');
});

test('computeEarnings: scales the daily rate to day/month/year + time-to-share', () => {
    const earnings = { available: true, coeff_day: 1e-7, pool_difficulty: 250_000_000 };
    const est = computeEarnings(50_000, earnings);
    assert.equal(est.day, 50_000 * 1e-7);
    assert.equal(est.month, est.day * DAYS_PER_MONTH);
    assert.equal(est.year, est.day * DAYS_PER_YEAR);
    // Expected seconds to a P2Pool share = share difficulty / hashrate.
    assert.equal(est.timeToShareSec, 250_000_000 / 50_000);
});

test('computeEarnings: returns nulls when unavailable or hashrate is non-positive', () => {
    const ok = { available: true, coeff_day: 1e-7, pool_difficulty: 1 };
    const allNull = { day: null, month: null, year: null, timeToShareSec: null,
                      tariDay: null, tariMonth: null, tariYear: null,
                      tariTimeToBlockSec: null, tariRewardPerBlock: null,
                      xvbDay: null, xvbMonth: null, xvbYear: null };
    assert.deepEqual(computeEarnings(0, ok), allNull);
    assert.deepEqual(computeEarnings(null, ok), allNull);
    // available:false (network stats missing) -> graceful "—" path even with a valid hashrate.
    assert.equal(computeEarnings(50_000, { available: false, coeff_day: 1e-7 }).day, null);
    assert.equal(computeEarnings(50_000, null).day, null);
});

test('computeEarnings: Tari figures scale with the same what-if input (#117)', () => {
    const earnings = { available: true, coeff_day: 1e-7, pool_difficulty: 1,
                       tari_available: true, tari_coeff_day: 2e-3 };
    const est = computeEarnings(50_000, earnings);
    assert.equal(est.tariDay, 50_000 * 2e-3);
    assert.equal(est.tariMonth, est.tariDay * DAYS_PER_MONTH);
    assert.equal(est.tariYear, est.tariDay * DAYS_PER_YEAR);
    // Doubling the hashrate doubles the XTM figures — one input drives both estimates.
    assert.equal(computeEarnings(100_000, earnings).tariDay, 2 * est.tariDay);
});

test('computeEarnings: solo Tari time-to-block = difficulty / hashrate, reward passed through', () => {
    // tari_difficulty carries seconds-to-block-per-H/s (== difficulty, guarded server-side).
    // Prod field numbers: diff ~1.677e12, fleet ~269 kH/s -> ~6.23e6 s (~72 days).
    const earnings = { available: true, coeff_day: 1e-7, pool_difficulty: 1,
                       tari_available: true, tari_coeff_day: 2e-3,
                       tari_difficulty: 1.677e12, tari_reward: 10_709 };
    const est = computeEarnings(269_000, earnings);
    assert.equal(est.tariTimeToBlockSec, 1.677e12 / 269_000);
    assert.ok(est.tariTimeToBlockSec / 86_400 > 70 && est.tariTimeToBlockSec / 86_400 < 74);
    assert.equal(est.tariRewardPerBlock, 10_709);
    // More hashrate finds the block sooner (inverse), so time-to-block halves when hashrate doubles.
    assert.equal(computeEarnings(538_000, earnings).tariTimeToBlockSec, est.tariTimeToBlockSec / 2);
    // The duration formatter renders the ~72-day span as days, not a huge hour count.
    assert.match(formatTimeToShare(est.tariTimeToBlockSec), /^\d+d/);
});

test('computeEarnings: Tari figures are null when merge-mining is unavailable (#117)', () => {
    const est = computeEarnings(50_000, {
        available: true, coeff_day: 1e-7, pool_difficulty: 1,
        tari_available: false, tari_coeff_day: 0, tari_difficulty: 0, tari_reward: 0,
    });
    assert.equal(est.tariDay, null);
    assert.equal(est.tariMonth, null);
    assert.equal(est.tariYear, null);
    assert.equal(est.tariTimeToBlockSec, null);
    assert.equal(est.tariRewardPerBlock, null);
    assert.ok(est.day > 0);   // the XMR estimate is unaffected
});

test('computeEarnings: a known per-block reward survives a dead channel and a zero hashrate (#992)', () => {
    // The reward is a chain fact the TariCard prints on the same page — only the estimates
    // (time-to-block, per-day averages) depend on tari_available and the what-if hashrate.
    const earnings = { available: true, coeff_day: 1e-7, pool_difficulty: 1,
                       tari_available: false, tari_coeff_day: 0, tari_difficulty: 0,
                       tari_reward: 10_709 };
    const est = computeEarnings(50_000, earnings);
    assert.equal(est.tariRewardPerBlock, 10_709);
    assert.equal(est.tariTimeToBlockSec, null);  // the time estimate stays gated
    assert.equal(est.tariDay, null);
    // Hashrate-independent: the zero-hashrate early return keeps the known reward too.
    assert.equal(computeEarnings(0, earnings).tariRewardPerBlock, 10_709);
});

test('computeEarnings: no time-to-share when share difficulty is unknown', () => {
    const est = computeEarnings(50_000, { available: true, coeff_day: 1e-7, pool_difficulty: 0 });
    assert.equal(est.timeToShareSec, null);
    assert.ok(est.day > 0);   // earnings still computed
});

test('formatXmr: precision scales with magnitude; "—" for null/invalid', () => {
    assert.equal(formatXmr(2.5), '2.5000 XMR');        // >= 1 -> 4 dp
    assert.equal(formatXmr(0.1234567), '0.123457 XMR'); // >= 0.001 -> 6 dp
    assert.equal(formatXmr(0.00000123), '0.00000123 XMR'); // tiny -> 8 dp, not rounded to 0
    assert.equal(formatXmr(0), '0 XMR');
    assert.equal(formatXmr(null), '—');
    assert.equal(formatXmr(Infinity), '—');
});

test('formatXtm: same adaptive precision with the XTM unit; "—" for null (#117)', () => {
    assert.equal(formatXtm(2.5), '2.5000 XTM');
    assert.equal(formatXtm(0), '0 XTM');
    assert.equal(formatXtm(null), '—');   // the Tari-unavailable "—" state
});

test('formatTimeToShare: formats seconds, "—" for null / non-positive', () => {
    assert.equal(formatTimeToShare(5400), '1h 30m');
    assert.equal(formatTimeToShare(90), '1m 30s');
    assert.equal(formatTimeToShare(null), '—');
    assert.equal(formatTimeToShare(0), '—');
    assert.equal(formatTimeToShare(Infinity), '—');
});
