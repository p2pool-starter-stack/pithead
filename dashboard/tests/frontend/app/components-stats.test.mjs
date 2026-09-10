import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clone, renderApp } from '../harness.mjs';

test('CadenceCard shows the — placeholders on a cold stack, real figures when available (#84)', () => {
    // The base fixture has no pool difficulty → cadence.available === false → server-sent dashes.
    const cold = renderApp();
    assert.match(cold, /Pool Cadence & Luck/);
    assert.match(cold, /Since Pool's Last Block/);
    assert.match(cold, /Est\. Time \/ Share/);
    assert.match(cold, /Your PPLNS Weight/);
    assert.match(cold, /—/);
    // With server-computed figures, the card renders them verbatim (no client-side math).
    const s = clone();
    s.cadence = {
        last_block: '12:34:56', since_block: '5m 0s', tts: '1h 0m',
        luck: '123%', weight: '1,234,567', available: true,
    };
    const up = renderApp({ state: s });
    assert.match(up, /5m 0s/);
    assert.match(up, /1h 0m/);
    assert.match(up, /123%/);
    assert.match(up, /1,234,567/);
});

test('XvBStats greys the credited figures and flags the footer when the fetch is stale (#311)', () => {
    // Fresh (base fixture, xvb_stale false): the normal "Stats fetched" footer, no stale marks.
    const fresh = renderApp();
    assert.match(fresh, /Stats fetched from xmrvsbeast\.com \(Updated:/);
    assert.doesNotMatch(fresh, /Stale —/);
    assert.doesNotMatch(fresh, /Credited\) ⚠/);
    // Stale: credited labels get a ⚠, the footer flips to the stale warning, status-warn applied.
    const s = clone();
    s.hashrate.xvb_stale = true;
    const stale = renderApp({ state: s });
    assert.match(stale, /1h Avg \(Credited\) ⚠/);
    assert.match(stale, /24h Avg \(Credited\) ⚠/);
    assert.match(stale, /⚠ Stale — last successful fetch from xmrvsbeast\.com/);
    assert.match(stale, /status-warn/);
});

test('XvBStats lists recorded raffle wins, with a placeholder when there are none', () => {
    // The base fixture carries one recorded win → the wins log shows it, no placeholder.
    const withWin = renderApp();
    assert.match(withWin, /Raffle Wins/);
    assert.match(withWin, /won a donor_whale round, credited 4\.20 MH\/s/);
    assert.doesNotMatch(withWin, /No wins recorded yet/);
    // No wins → the muted placeholder pointing at the chart's gold-star marker.
    const s = clone();
    s.raffle_wins = [];
    const empty = renderApp({ state: s });
    assert.match(empty, /No wins recorded yet/);
    assert.doesNotMatch(empty, /won a donor_whale round/);
});
