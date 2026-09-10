import { test } from 'node:test';
import assert from 'node:assert/strict';
import { computeEarnings, computeEnergy, formatFiat, formatFiatAmount, formatUnit, coinTriplet, coinFiat, formatFiatPrice, priceSourceLabel, DAYS_PER_MONTH, DAYS_PER_YEAR } from '../../../mining_dashboard/web/static/app/logic.mjs';

// --- Energy & profit calculator (#260) --------------------------------------------------

test('computeEnergy: kWh from measured watts, naive extrapolation', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0, xmr_price: 0 },
        { day: 0 },
    );
    assert.equal(en.kwhDay, 24);                      // 1000 W = 1 kW * 24h
    assert.equal(en.kwhMonth, 24 * DAYS_PER_MONTH);
    assert.equal(en.kwhYear, 24 * DAYS_PER_YEAR);
    assert.equal(en.costDay, null);                   // no price -> no cost
    assert.equal(en.netDay, null);
});

test('computeEnergy: cost appears once cost_per_kwh is set', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 0 },
        { day: 0.01 },
    );
    assert.equal(en.costDay, 24 * 0.2);               // 24 kWh * 0.2
    assert.equal(en.netDay, null);                    // no xmr_price -> no net
});

test('computeEnergy: net = gross(XMR*price) - cost when both prices set', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 150 },
        { day: 0.1 },                                  // 0.1 XMR/day
    );
    // gross = 0.1 * 150 = 15; cost = 24 * 0.2 = 4.8; net = 10.2
    assert.ok(Math.abs(en.netDay - 10.2) < 1e-9);
    assert.ok(Math.abs(en.netYear - 10.2 * DAYS_PER_YEAR) < 1e-6);
});

test('computeEnergy: negative net survives (power costs more than it earns)', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 1, xmr_price: 1 },
        { day: 0.001 },
    );
    assert.ok(en.netDay < 0);
});

test('computeEnergy: unavailable / zero watts returns all nulls', () => {
    for (const bad of [null, { available: false }, { available: true, total_watts: 0 }]) {
        const en = computeEnergy(bad, { day: 1 });
        assert.equal(en.kwhDay, null);
        assert.equal(en.netDay, null);
        assert.equal(en.includesTari, false);
    }
});

// --- Tari revenue in net profit (#520) ---------------------------------------------------

test('computeEnergy: both prices set -> gross combines P2Pool XMR + Tari', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 150, tari_price: 2 },
        { day: 0.1, tariDay: 5 }, // 0.1 XMR/day, 5 XTM/day
    );
    // gross = 0.1*150 + 5*2 = 15 + 10 = 25; cost = 24*0.2 = 4.8; net = 20.2
    assert.ok(Math.abs(en.netDay - 20.2) < 1e-9);
    assert.equal(en.includesTari, true);
});

test('computeEnergy: only xmr_price set -> P2Pool-only net, includesTari false', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 150, tari_price: 0 },
        { day: 0.1, tariDay: 5 }, // Tari estimate exists but is unpriced
    );
    // gross = 0.1*150 = 15 (Tari excluded); cost = 4.8; net = 10.2
    assert.ok(Math.abs(en.netDay - 10.2) < 1e-9);
    assert.equal(en.includesTari, false);
});

// --- Fiat estimates + price provenance (#520 price feed) ---------------------------------

test('coinFiat: multiplies only when both estimate and positive price exist', () => {
    assert.equal(coinFiat(0.1, 150), 15);
    assert.equal(coinFiat(null, 150), null);   // no estimate -> no fiat row
    assert.equal(coinFiat(0.1, 0), null);      // unset price -> no fiat row
    assert.equal(coinFiat(0.1, undefined), null);
});

test('formatFiatPrice: scales decimals so a tiny XTM price never reads 0.00', () => {
    assert.equal(formatFiatPrice(333.97, 'USD'), 'USD 333.97');
    assert.equal(formatFiatPrice(0.0004, 'USD'), 'USD 0.000400');
    assert.equal(formatFiatPrice(0.0521, 'EUR'), 'EUR 0.0521');
    assert.equal(formatFiatPrice(0, 'USD'), '—');   // unset price
});

test('priceSourceLabel: live feed states source and age', () => {
    const label = priceSourceLabel({
        xmr_price: 333.97, tari_price: 0.0004, currency: 'USD',
        price_source: { feed: true, live: true, age_sec: 720 },
    });
    assert.match(label, /CoinGecko over Tor/);
    assert.match(label, /12m ago/);
});

test('priceSourceLabel: feed waiting vs static vs nothing to attribute', () => {
    // Feed on, first fetch pending -> says the static values still stand.
    assert.match(
        priceSourceLabel({ xmr_price: 150, tari_price: 0, price_source: { feed: true, live: false } }),
        /waiting.*static/,
    );
    // Feed off with a static price -> attributed to config.json.
    assert.match(
        priceSourceLabel({ xmr_price: 150, tari_price: 0, price_source: { feed: false, live: false } }),
        /static, set in config\.json/,
    );
    // No prices, no feed -> null (no fiat figures exist, nothing to attribute).
    assert.equal(
        priceSourceLabel({ xmr_price: 0, tari_price: 0, price_source: { feed: false, live: false } }),
        null,
    );
    assert.equal(priceSourceLabel(null), null);
});

test('computeEnergy: tari_price set but no xmr_price -> no net at all (xmr_price is the base gate)', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 0, tari_price: 2 },
        { day: 0.1, tariDay: 5 },
    );
    assert.equal(en.netDay, null);
    assert.equal(en.includesTari, false);
});

test('computeEnergy: tari_price set but Tari not merge-mining (tariDay null) -> P2Pool-only', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 150, tari_price: 2 },
        { day: 0.1, tariDay: null },
    );
    assert.ok(Math.abs(en.netDay - 10.2) < 1e-9); // same as P2Pool-only case above
    assert.equal(en.includesTari, false);
});

// --- Standardized estimate tables --------------------------------------------------------

test('coinTriplet: one shared precision across a Day/Month/Year column, from the smallest value', () => {
    // Day figure (smallest) is < 0.001 -> 8 dp for all three rows, so the column aligns.
    assert.deepEqual(
        coinTriplet([0.00092945, 0.0278835, 0.33925025], 'XMR'),
        ['0.00092945 XMR', '0.02788350 XMR', '0.33925025 XMR'],
    );
    // Day >= 1 -> 4 dp everywhere.
    assert.deepEqual(
        coinTriplet([505.54, 15166.2, 184522.1], 'XTM'),
        ['505.5400 XTM', '15166.2000 XTM', '184522.1000 XTM'],
    );
    // Nulls render "—" without disturbing the shared precision of the rest.
    assert.deepEqual(coinTriplet([null, 2.5, null], 'XMR'), ['—', '2.5000 XMR', '—']);
    // All-null (estimate unavailable) -> three dashes, no NaN.
    assert.deepEqual(coinTriplet([null, null, null], 'XMR'), ['—', '—', '—']);
    assert.deepEqual(coinTriplet([0, 0, 0], 'XMR'), ['0 XMR', '0 XMR', '0 XMR']);
});

test('formatFiatAmount: bare 2-dp amount for table cells, sign kept, "—" for null', () => {
    assert.equal(formatFiatAmount(12.345), '12.35');
    assert.equal(formatFiatAmount(-3.2), '-3.20');
    assert.equal(formatFiatAmount(0), '0.00');
    assert.equal(formatFiatAmount(null), '—');
    assert.equal(formatFiatAmount(Infinity), '—');
});

test('formatUnit: empty unit gives the bare number (table cells whose header names the unit)', () => {
    assert.equal(formatUnit(6.43, ''), '6.4');
    assert.equal(formatUnit(6.43, 'kWh'), '6.4 kWh');
});

test('computeEarnings: xvb day/month/year are plain spans of the published figure', () => {
    const est = computeEarnings(50_000, {
        available: true, coeff_day: 1e-7, pool_difficulty: 1, xvb_day: 0.02,
    });
    assert.equal(est.xvbDay, 0.02);
    assert.equal(est.xvbMonth, 0.02 * DAYS_PER_MONTH);
    assert.equal(est.xvbYear, 0.02 * DAYS_PER_YEAR);
    // No fresh estimate -> the whole triplet is null, never fabricated.
    const none = computeEarnings(50_000, { available: true, coeff_day: 1e-7, pool_difficulty: 1 });
    assert.equal(none.xvbDay, null);
    assert.equal(none.xvbMonth, null);
    assert.equal(none.xvbYear, null);
});

test('computeEnergy: gross revenue surfaced as day/month/year (the sum the net starts from)', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 150 },
        { day: 0.1 },
    );
    assert.equal(en.grossDay, 0.1 * 150);
    assert.equal(en.grossMonth, en.grossDay * DAYS_PER_MONTH);
    assert.equal(en.grossYear, en.grossDay * DAYS_PER_YEAR);
    assert.ok(Math.abs(en.grossDay - en.costDay - en.netDay) < 1e-9);
    // Gates mirror net: no XMR price -> no gross (cost can still stand alone).
    const noPrice = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2 },
        { day: 0.1 },
    );
    assert.equal(noPrice.grossDay, null);
    assert.equal(noPrice.grossMonth, null);
    assert.equal(noPrice.grossYear, null);
    assert.ok(noPrice.costDay > 0);
    // The other direction: xmr_price set but no cost_per_kwh -> gross stands alone, net nulls
    // (net needs BOTH sides; a gross-only net would silently read as free electricity).
    const noCost = computeEnergy(
        { available: true, total_watts: 1000, xmr_price: 150 },
        { day: 0.1 },
    );
    assert.ok(noCost.grossDay > 0);
    assert.equal(noCost.costDay, null);
    assert.equal(noCost.netDay, null);
    assert.equal(noCost.netMonth, null);
    assert.equal(noCost.netYear, null);
});

// --- XvB folded into net profit (#712) ---------------------------------------------------

test('computeEnergy: xvbDay grows net by xvbDay*xmr_price and sets includesXvb', () => {
    const base = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 150 },
        { day: 0.1 },
    );
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 150 },
        { day: 0.1, xvbDay: 0.02 }, // current-tier XvB expected reward, XMR/day
    );
    // gross adds 0.02*150 = 3 on top of the P2Pool-only net.
    assert.ok(Math.abs(en.netDay - (base.netDay + 3)) < 1e-9);
    assert.equal(en.includesXvb, true);
    assert.equal(en.includesTari, false);
});

test('computeEnergy: null/zero xvbDay leaves net + includesXvb untouched (no fabrication)', () => {
    const base = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 150 },
        { day: 0.1 },
    );
    for (const xvbDay of [null, undefined, 0]) {
        const en = computeEnergy(
            { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 150 },
            { day: 0.1, xvbDay },
        );
        assert.ok(Math.abs(en.netDay - base.netDay) < 1e-9);
        assert.equal(en.includesXvb, false);
    }
});

test('computeEnergy: xvbDay set but xmr_price 0 -> not included (XvB valued at XMR price)', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 0 },
        { day: 0.1, xvbDay: 0.02 },
    );
    assert.equal(en.netDay, null);        // no xmr_price -> no net at all
    assert.equal(en.includesXvb, false);  // never fabricate a figure without a price
});

test('formatFiat: currency label, two decimals, keeps the sign', () => {
    assert.equal(formatFiat(12.5, 'USD'), 'USD 12.50');
    assert.equal(formatFiat(-3, 'EUR'), '-EUR 3.00');
    assert.equal(formatFiat(null, 'USD'), '—');
});

test('formatUnit: value + unit, "—" for null', () => {
    assert.equal(formatUnit(142.0, 'W'), '142.0 W');
    assert.equal(formatUnit(20, 'H/s·W', 2), '20.00 H/s·W');
    assert.equal(formatUnit(null, 'kWh'), '—');
});
