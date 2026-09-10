import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clone, renderApp } from '../harness.mjs';

test('EarningsCard Energy tab folds Tari into net profit once tari_price is set and Tari is merge-mining (#520)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.earnings.tari_available = true;
    s.earnings.tari_coeff_day = 1e-6;
    s.energy.cost_per_kwh = 0.2;
    s.energy.xmr_price = 150;
    s.energy.tari_price = 2;
    const html = renderApp({ state: s });
    assert.match(html, /scope="col"[^>]*>Net</);
    assert.match(html, /P2Pool \+ Tari, after power/);
    assert.doesNotMatch(html, /P2Pool XMR only, after power/);
});

test('EarningsCard Energy tab keeps the P2Pool-only label when tari_price is set but Tari is not merge-mining (#520)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.earnings.tari_available = false; // no Tari estimate to fold in
    s.energy.cost_per_kwh = 0.2;
    s.energy.xmr_price = 150;
    s.energy.tari_price = 2;
    const html = renderApp({ state: s });
    assert.match(html, /scope="col"[^>]*>Net</);
    assert.match(html, /P2Pool XMR only, after power/);
    assert.doesNotMatch(html, /P2Pool \+ Tari, after power/);
});

test('EarningsCard Energy tab folds the current-tier XvB estimate into net, labelled an estimate (#712)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.earnings.xvb_day = 0.02; // server-derived current-tier expected reward, XMR/day
    s.energy.cost_per_kwh = 0.2;
    s.energy.xmr_price = 150;
    const html = renderApp({ state: s });
    assert.match(html, /scope="col"[^>]*>Net</);
    assert.match(html, /P2Pool \+ XvB \(est\.\), after power/);
    // Tooltip drops the "Excludes XvB" clause and states it's an estimate — tempered by
    // measured delivery, never face value (#902).
    assert.match(html, /XvB is an estimate, tempered by measured delivery/);
    assert.match(html, /never XvB(?:'|&#39;)s face value/);
    assert.doesNotMatch(html, /Excludes XvB/);
    assert.doesNotMatch(html, /P2Pool XMR only, after power/);
});

test('EarningsCard Energy tab: net label/tooltip byte-identical to pre-#712 when no XvB estimate', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.earnings.xvb_day = null; // no fresh estimate → XvB not folded in
    s.energy.cost_per_kwh = 0.2;
    s.energy.xmr_price = 150;
    const html = renderApp({ state: s });
    assert.match(html, /P2Pool XMR only, after power/);
    // The exact pre-#712 tooltip, XvB still called out as excluded.
    assert.match(
        html,
        /Excludes Tari \(set dashboard\.energy\.tari_price to include it\) and XvB \(raffle status, not a per-day income estimate\)\./,
    );
    assert.doesNotMatch(html, /XvB \(est\.\)/);
    assert.doesNotMatch(html, /XvB is an estimate/);
});

test('EarningsCard grows fiat rows + a price provenance line once a price is known (#520)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.earnings.tari_available = true;
    s.earnings.tari_coeff_day = 1e-6;
    // No price anywhere → no fiat columns, no provenance line (nothing to attribute).
    let html = renderApp({ state: s });
    assert.doesNotMatch(html, /≈ USD/);
    assert.doesNotMatch(html, /id="earnings-price-source"/);
    // Static prices set → the Monero + Tari estimate tables grow a ≈-fiat column, XvB gets its
    // fiat mirror line, and the footer attributes the prices to config.json.
    s.energy.xmr_price = 150;
    s.energy.tari_price = 2;
    html = renderApp({ state: s });
    assert.match(html, /≈ USD/); // fiat column header in the estimate tables
    assert.match(html, /≈ per Block/); // Tari tab per-block fiat card
    assert.match(html, /id="xvb-fiat-line"/); // XvB tab fiat mirror
    assert.match(html, /id="earnings-price-source"/);
    assert.match(html, /USD 150\.00/); // the XMR price in use, stated
    assert.match(html, /static, set in config\.json/);
});

test('EarningsCard shows Confirmed on-chain under the estimates on both tabs when payout confirmation is on (#381)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.tari_available = true;
    s.earnings.tari_coeff_day = 2e-3;
    s.earnings.confirmed = {
        enabled: true, count: 3, xmr_24h: 0.25, xmr_yesterday: 0.5, xmr_7d: 0.75,
        xmr_30d: 1.25, xmr_all: 1.75,
        last_ts: Math.floor(Date.now() / 1000) - 3600,
        since_ts: Math.floor(Date.now() / 1000) - 90 * 86400,
        partial: { yesterday: false, '7d': false, '30d': false },
    };
    s.earnings.tari_confirmed = {
        enabled: true, count: 1, xtm_24h: 0, xtm_yesterday: 0, xtm_7d: 4552.15,
        xtm_30d: 4552.15, xtm_all: 4552.15,
        last_ts: Math.floor(Date.now() / 1000) - 7200,
        since_ts: Math.floor(Date.now() / 1000) - 90 * 86400,
        partial: { yesterday: false, '7d': false, '30d': false },
    };
    let html = renderApp({ state: s });
    // One confirmed block per tab (counted by the sub-panel's own class — the phrase also
    // appears in the #808 card's tooltip prose), populated through the coin formatters.
    assert.equal(html.split('confirmed-subhead').length - 1, 2);
    assert.match(html, /0\.250000 XMR/);   // xmr_24h
    assert.match(html, /1\.7500 XMR/);     // xmr_all
    assert.match(html, /4552\.1500 XTM/);  // xtm_all
    assert.match(html, /Last payout/);
    // Running windows (#787): yesterday / 7d / 30d beside the existing 24h and all-time figures.
    assert.match(html, /Yesterday/);
    assert.match(html, /Running 7d/);
    assert.match(html, /Running 30d/);
    assert.match(html, /0\.500000 XMR/);   // xmr_yesterday
    assert.match(html, /1\.2500 XMR/);     // xmr_30d
    // History predates every window here, so nothing is marked partial and no footnote appears.
    assert.doesNotMatch(html, /Partial/);
    // Estimates first, confirmed reality after — on the Tari tab the block follows the
    // Long-run Average table, mirroring the Monero tab's order.
    const tari = html.slice(html.indexOf('id="epanel-tari"'), html.indexOf('id="epanel-xvb"'));
    assert.ok(tari.indexOf('Long-run Average') < tari.indexOf('Confirmed on-chain'));
    // Confirmation off (the default) -> no confirmed block anywhere, estimates stand alone.
    s.earnings.confirmed = { enabled: false };
    s.earnings.tari_confirmed = { enabled: false };
    html = renderApp({ state: s });
    // Scoped to the sub-panel class — the #808 card's tooltip prose reuses the phrase.
    assert.doesNotMatch(html, /confirmed-subhead/);
});

test('EarningsCard marks running windows the payout history does not fully cover (#787)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.tari_confirmed = { enabled: false };
    // History starts 3 days ago: yesterday is covered, 7d and 30d reach behind it.
    s.earnings.confirmed = {
        enabled: true, count: 1, xmr_24h: 0, xmr_yesterday: 0.5, xmr_7d: 0.5,
        xmr_30d: 0.5, xmr_all: 0.5,
        last_ts: Math.floor(Date.now() / 1000) - 3 * 86400,
        since_ts: Math.floor(Date.now() / 1000) - 3 * 86400,
        partial: { yesterday: false, '7d': true, '30d': true },
    };
    let html = renderApp({ state: s });
    // Only the flagged windows carry the marker — a covered window must not be hedged.
    assert.match(html, /Running 7d \*/);
    assert.match(html, /Running 30d \*/);
    assert.doesNotMatch(html, /Yesterday \*/);
    // One footnote states where the recorded history starts, so a short window never reads as full.
    assert.match(html, /payout history starts/);
    assert.match(html, /covers only the history on record/);
    // Nothing confirmed at all: every running window is flagged and the footnote says so instead
    // of naming a date it doesn't have.
    s.earnings.confirmed = {
        enabled: true, count: 0, xmr_24h: 0, xmr_yesterday: 0, xmr_7d: 0, xmr_30d: 0, xmr_all: 0,
        last_ts: 0, since_ts: 0,
        partial: { yesterday: true, '7d': true, '30d': true },
    };
    html = renderApp({ state: s });
    assert.match(html, /Yesterday \*/);
    assert.match(html, /no payouts on record yet/);
});

test('EarningsCard XvB tab shows the tempered current-tier reward as a day/month/year table', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.xvb_day = 0.002; // fresh (server-tempered, #902) estimate → the standardized table
    let html = renderApp({ state: s });
    // The heading says the figure is tempered by measured delivery, not XvB's face value (#902).
    assert.match(html, /Current Tier Expected Reward — tempered by measured delivery/);
    assert.match(html, /tempered by measured delivery: scaled to what this wallet/);
    assert.match(html, /0\.002000 XMR/);  // day
    assert.match(html, /0\.060000 XMR/);  // month, same shared precision
    assert.match(html, /0\.730000 XMR/);  // year
    // No fresh estimate → no table, nothing fabricated.
    s.earnings.xvb_day = null;
    html = renderApp({ state: s });
    assert.doesNotMatch(html, /Current Tier Expected Reward/);
});

test('EarningsCard Energy tab: revenue in accent, net carries the green/red sign colour', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.energy.cost_per_kwh = 0.2;
    s.energy.xmr_price = 150;
    // Fixture fleet earns less than power costs at these figures → net is negative → c-bad.
    let html = renderApp({ state: s });
    assert.match(html, /class="c-bad"[^>]*>-/);
    // A richer rate flips the net positive → c-ok, revenue stays accent either way.
    s.earnings.coeff_day = 1e-5;
    html = renderApp({ state: s });
    assert.match(html, /class="c-ok"/);
    assert.match(html, /class="c-accent"/);
});

test('EarningsCard provenance line reflects the live price feed (#520)', () => {
    const s = clone();
    s.earnings.available = true;
    s.energy.xmr_price = 333.97;
    s.energy.tari_price = 0.0004;
    s.energy.price_source = { feed: true, live: true, age_sec: 720 };
    const html = renderApp({ state: s });
    assert.match(html, /live from CoinGecko over Tor/);
    assert.match(html, /12m ago/);
    assert.match(html, /USD 0\.000400/); // tiny XTM price keeps its precision
});
