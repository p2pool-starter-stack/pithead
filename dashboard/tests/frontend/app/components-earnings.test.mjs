import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clone, renderApp } from '../harness.mjs';

test('EarningsCard shows the fallback when stats are down, the calculator when available', () => {
    // The base fixture has earnings.available === false → the fallback copy, no what-if input.
    const down = renderApp();
    assert.match(down, /the estimate can't be computed right now/);
    assert.doesNotMatch(down, /whatif-hr/);
    // With stats available, the class component renders its what-if input (local UI state).
    const s = clone();
    s.earnings.available = true;
    const up = renderApp({ state: s });
    assert.match(up, /Your P2Pool Hashrate/);
    assert.match(up, /id="whatif-hr"/);
});

test('EarningsCard leads with solo time-to-block + per-block reward, day as avg (#117)', () => {
    // Merge-mining live: the honest solo headline is time-to-block and the whole per-block reward.
    const s = clone();
    s.earnings.available = true;
    s.earnings.tari_available = true;
    s.earnings.tari_coeff_day = 2e-3;   // × p2pool_hr (8050) → 16.1 XTM/day (long-run avg)
    s.earnings.tari_difficulty = 1.677e12;  // seconds-to-block per H/s; ÷ 8050 → ~2410 days
    s.earnings.tari_reward = 10_709;
    const up = renderApp({ state: s });
    assert.match(up, /Est\. Time to Tari Block/);
    assert.match(up, /XTM per Block/);
    assert.match(up, /10709\.0000 XTM/);   // the full block reward
    // Per-day/month/year kept, in the standardized table under a not-steady-income heading.
    assert.match(up, /Long-run Average — not steady income/);
    assert.match(up, /16\.1000 XTM/);       // the long-run daily average figure still shown
    assert.match(up, /483\.0000 XTM/);      // ... spanned to month
    assert.match(up, /5876\.5000 XTM/);     // ... and year, same shared precision
    // Merge-mining inactive/syncing: the estimates degrade to "—", but a KNOWN per-block
    // reward keeps showing — it is a fact about the chain (the Tari Merge-Mining card prints
    // the same figure), not a function of this box's hashrate or channel state.
    const off = clone();
    off.earnings.available = true;
    off.earnings.tari_available = false;
    off.earnings.tari_reward = 10_709;
    const down = renderApp({ state: off });
    assert.match(down, /Est\. Time to Tari Block/);
    assert.match(down, /—/);
    assert.match(down, /10709\.0000 XTM/);
    assert.doesNotMatch(down, /NaN/);
});

test('EarningsCard renders the XvB tier (raffle) block on and off — off drops the live-credit cards (#938)', () => {
    const s = clone();
    s.earnings.available = true;
    s.xvb_calc = {
        enabled: true,
        max_fraction: 0.85,
        tiers: [
            { name: 'Donor (1.00 kH/s+)', threshold: 1000 },
            { name: 'Vip (10.00 kH/s+)', threshold: 10000 },
        ],
        current_tier: 'None',
        target_tier: 'Donor (1.00 kH/s+)',
        target_threshold: 1000,
        sustainable: true,
        note: 'An XvB tier is raffle status, not an XMR payout.',
        mode_note: null,
    };
    const up = renderApp({ state: s });
    assert.match(up, /XvB Tier \(raffle\)/);
    // Default what-if hashrate (p2pool_hr ≈ 8k) × 0.85 sustains the Donor tier, not Vip —
    // the client-side transcription of the server's auto rule, with cost = the threshold.
    assert.match(up, /Sustainable Tier/);
    assert.match(up, /Donor \(1\.00 kH\/s\+\)/);
    assert.match(up, /Hashrate Cost/);
    assert.match(up, /1\.00 kH\/s/);
    assert.match(up, /not an XMR payout/);   // the required labelling rides on the card
    assert.doesNotMatch(up, /id="xvb-disabled-note"/); // the off-explainer only shows off
    // XvB disabled (#938): the decision aid stays — what-if cards, table, note — but the
    // live-credit cards (Current/Target tier) stand down and the off-explainer appears.
    s.xvb_calc = { ...s.xvb_calc, enabled: false, current_tier: 'Disabled', target_tier: 'Disabled' };
    const off = renderApp({ state: s });
    assert.match(off, /XvB Tier \(raffle\)/);
    assert.match(off, /Sustainable Tier/);
    assert.match(off, /Hashrate Cost/);
    assert.match(off, /id="xvb-disabled-note"/);
    assert.match(off, /not an XMR payout/);
    assert.doesNotMatch(off, /Current Tier/);
    assert.doesNotMatch(off, /Target Tier/);
    assert.match(off, /Your P2Pool Hashrate/);
});

test('EarningsCard splits into Monero / Tari / XvB tabs, Monero active by default (#118)', () => {
    const s = clone();
    s.earnings.available = true;
    // XvB on → three tabs; the XvB tab only exists when XvB is enabled.
    const html = renderApp({ state: s });
    assert.match(html, /role="tablist"/);
    assert.match(html, /id="etab-monero"[^>]*>Monero</);
    assert.match(html, /id="etab-tari"[^>]*>Tari</);
    assert.match(html, /id="etab-xvb"[^>]*>XvB</);
    // Default active tab = Monero: it is aria-selected and its panel is visible; the others hidden.
    assert.match(html, /id="etab-monero"[^>]*aria-selected="true"/);
    assert.match(html, /id="etab-tari"[^>]*aria-selected="false"/);
    assert.match(html, /id="epanel-monero"[^>]*aria-labelledby="etab-monero">/); // no `hidden` → shown
    assert.match(html, /id="epanel-tari"[^>]*hidden>/); // inactive panel hidden
    assert.match(html, /id="epanel-xvb"[^>]*hidden>/);
    // The shared what-if input sits above the tab strip, so it drives all three tabs.
    assert.match(html, /id="whatif-hr"/);
    // The Monero panel carries the XMR estimate table, the Tari panel the solo time-to-block,
    // the XvB panel the tier block — all present in the DOM (inactive ones just hidden).
    assert.match(html, /class="est-table"/);
    assert.match(html, /scope="row">Day</);
    assert.match(html, /scope="row">Month</);
    assert.match(html, /scope="row">Year</);
    assert.match(html, /Est\. Time to Tari Block/);
    assert.match(html, /XvB Tier \(raffle\)/);
});

test('EarningsCard keeps the XvB tab when disabled; only a tier-less payload drops it (#938)', () => {
    const s = clone();
    s.earnings.available = true;
    // Disabled with a tier table (what the server now always sends): the tab stays — it holds
    // the enable/don't-enable decision aid.
    s.xvb_calc = {
        enabled: false, max_fraction: 0.85,
        tiers: [{ name: 'Donor (1.00 kH/s+)', threshold: 1000 }],
        current_tier: 'Disabled', target_tier: 'Disabled',
        note: 'raffle status', mode_note: null,
    };
    let html = renderApp({ state: s });
    assert.match(html, /id="etab-xvb"/);
    assert.match(html, /id="epanel-xvb"/);
    assert.match(html, /XvB Tier \(raffle\)/);
    // A pre-#938 disabled payload carries no tiers — nothing to price, so no tab either.
    s.xvb_calc = { enabled: false };
    html = renderApp({ state: s });
    assert.match(html, /id="etab-monero"/);
    assert.match(html, /id="etab-tari"/);
    assert.doesNotMatch(html, /id="etab-xvb"/);
    assert.doesNotMatch(html, /id="epanel-xvb"/);
    assert.doesNotMatch(html, /XvB Tier \(raffle\)/);
});

test('EarningsCard shows an Energy tab only when the fleet reports power (#260)', () => {
    const s = clone();
    s.earnings.available = true;
    // Fixture has an available energy block → the Energy tab and panel exist.
    let html = renderApp({ state: s });
    assert.match(html, /id="etab-energy"[^>]*>Energy</);
    assert.match(html, /id="epanel-energy"[^>]*hidden>/); // present but inactive (Monero default)
    assert.match(html, /Fleet Power/);
    assert.match(html, /285\.0 W/); // measured fleet draw from the fixture
    // No electricity price set → the prompt to set cost_per_kwh, and no net-profit figures.
    assert.match(html, /cost_per_kwh/);
    assert.doesNotMatch(html, /Net \/ day/);
    // With no power at all, the Energy tab disappears entirely.
    s.energy = { available: false };
    html = renderApp({ state: s });
    assert.doesNotMatch(html, /id="etab-energy"/);
    assert.doesNotMatch(html, /id="epanel-energy"/);
});

test('EarningsCard Energy tab shows cost then net as prices are set (#260)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8; // small XMR/H/s/day so gross stays sane
    s.energy.cost_per_kwh = 0.2;
    s.energy.currency = 'EUR';
    // Only the electricity price set → the Power Cost column shows, revenue/net still gated on
    // xmr_price (with the hint naming the config key to set).
    let html = renderApp({ state: s });
    assert.match(html, /Power Cost/);
    assert.match(html, /dashboard\.energy\.xmr_price/);
    assert.doesNotMatch(html, /scope="col"[^>]*>Net</);
    assert.doesNotMatch(html, /Revenue \(est\.\)/);
    // Both prices set → the Revenue and Net columns appear, labelled P2Pool-only since
    // tari_price is still unset.
    s.energy.xmr_price = 150;
    html = renderApp({ state: s });
    assert.match(html, /Revenue \(est\.\)/);
    assert.match(html, /scope="col"[^>]*>Net</);
    assert.match(html, /P2Pool XMR only, after power/);
    assert.doesNotMatch(html, /P2Pool \+ Tari, after power/);
});
