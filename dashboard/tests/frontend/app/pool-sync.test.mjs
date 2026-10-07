import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardSlice, clone, renderApp } from '../harness.mjs';

function placeholder(syncing) {
    const state = clone();
    state.pool = { ...state.pool, syncing, hr: '10.00 kH/s', blocks: 50,
        sidechain_height: 3, miners: 870, diff: '0.10 M', total_hashes: 400000 };
    state.cadence = { ...state.cadence, luck: '123%' };
    return state;
}

test('sidechain sync replaces every global statistic and luck, preserving local hashrate', () => {
    const state = placeholder(true);
    const html = renderApp({ state });
    const global = cardSlice(html, 'card-global');
    assert.match(global, /P2Pool is syncing its sidechain/);
    for (const label of ['Pool Hashrate', 'Blocks Found', 'Sidechain Height', 'Miners',
        'Difficulty', 'PPLNS Weight', 'Total Hashes']) assert.doesNotMatch(global, new RegExp(label));
    assert.doesNotMatch(global, /10\.00 kH\/s|870|400000/);
    const cadence = cardSlice(html, 'card-cadence');
    assert.match(cadence, /P2Pool is syncing its sidechain/);
    assert.doesNotMatch(cadence, /123%|Est\. Time \/ Share|Your PPLNS Weight/);
    assert.ok(cardSlice(html, 'card-mynode').includes(state.hashrate.p2p_1h));
});

test('synced pool keeps its figures and luck', () => {
    const html = renderApp({ state: placeholder(false) });
    const global = cardSlice(html, 'card-global');
    assert.match(global, /10\.00 kH\/s/);
    assert.match(global, /Blocks Found/);
    assert.match(global, />50</);
    assert.match(cardSlice(html, 'card-cadence'), /123%/);
    assert.doesNotMatch(html, /P2Pool is syncing its sidechain/);
});
