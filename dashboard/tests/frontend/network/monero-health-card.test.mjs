import assert from 'node:assert/strict';
import { test } from 'node:test';
import { cardSlice, clone, renderApp } from '../harness.mjs';

// The XMR Network card's tick means "at the tip, with peers" (#2499): peers and the age of the
// last height change sit in the headline, red carries the numbers, and the tooltip says what green means.
const withHealth = (health) => {
    const s = clone();
    s.monero.health = health;
    return cardSlice(renderApp({ state: s }), 'card-network');
};

test('a peerless monerod reads red with the numbers on the card headline', () => {
    const card = withHealth({
        level: 'red', status: '0 outgoing peers for 11 min', peers: '0 out / 2 in',
        moved: '2m 5s ago', tooltip: 'Green means monerod is at the network tip with peers',
    });
    assert.match(card, /Node Health<\/p><p class="status-bad">0 outgoing peers for 11 min</);
    assert.match(card, /Peers<\/p><p class="status-bad">0 out \/ 2 in</);
    assert.match(card, /Height Moved<\/p><p class="status-bad">2m 5s ago</);
    assert.match(card, /title="Green means monerod is at the network tip with peers"/);
});

test('a healthy monerod reads green: at tip, with peers', () => {
    const card = withHealth({
        level: 'green', status: 'At tip, with peers', peers: '8 out / 3 in',
        moved: '1m 0s ago', tooltip: 't',
    });
    assert.match(card, /Node Health<\/p><p class="status-ok">At tip, with peers</);
    assert.match(card, /Peers<\/p><p class="status-ok">8 out \/ 3 in</);
});

test('a remote node stays neutral and says peers are not visible', () => {
    const card = withHealth({
        level: 'unknown', status: 'Peers not visible — no health verdict for this node',
        peers: '—', moved: '—', tooltip: 't',
    });
    assert.match(card, /Peers not visible/);
    assert.doesNotMatch(card, /status-bad|status-ok/);
});

test('a payload from before this shipped renders the card without a verdict', () => {
    const s = clone();
    delete s.monero.health;
    assert.match(cardSlice(renderApp({ state: s }), 'card-network'), /Node Health<\/p><p class="">—</);
});
