// The .onion URL under the header's hostname/IP line (#1853).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// New file rather than more of components.test.mjs, which is at its file-budget ceiling. The
// render cases go through the App root on the real build_state fixture, like every other card, so
// they exercise the true server contract; copyText is a pure function and is tested directly,
// because the render probe deliberately never invokes handlers.
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';

import { clone, renderApp } from '../harness.mjs';
import { renderToString } from '../helpers/render.mjs';
import { CLEAR_MS, OnionUrl, copyText, fetchClientKey } from '../../../mining_dashboard/web/static/network/onionurl.mjs';

// A run of one letter, not a realistic v3 address: nothing here depends on the characters, and a
// high-entropy literal is what puts a secret scanner on a test file that holds no secret.
const ADDR = 'a'.repeat(56) + '.onion';
const URL = `http://${ADDR}`;

// controlEnabled decides WHICH answer the client-auth note gives, so it is a parameter rather
// than the fixture's own value: the two branches are one boolean apart and both must be pinned.
const withOnion = (onion, controlEnabled = false) => {
    const s = clone();
    s.dashboard_onion = onion;
    s.control_enabled = controlEnabled;
    return renderApp({ state: s });
};

test('the onion URL renders under the host line, whole (#1853)', () => {
    const html = withOnion({ url: URL, client_auth: false });
    // Whole, not elided: 56 characters of base32 carry no redundancy, so a truncated address is
    // one that does not open — and copying it to a phone is the entire product here.
    assert.match(html, new RegExp(`<span class="font-mono">${URL}</span>`));
    // It belongs to the header's address block, not to some card lower down the page. Anchor on
    // a marker that must exist: indexOf(-1) would slice the whole page and pass vacuously.
    assert.ok(html.includes('hero-band'), 'the hero band anchor is gone — re-anchor this slice');
    const header = html.slice(0, html.indexOf('hero-band'));
    assert.ok(header.includes(URL), 'the onion URL is not in the header block');
});

test('no onion means no block at all — not an empty row (#1853)', () => {
    // An empty row reads as "Tor is broken" rather than "Tor is off".
    assert.doesNotMatch(withOnion(null), /\.onion/);
    assert.doesNotMatch(withOnion(undefined), /\.onion/);
    // The control: the same fixture, one field filled, does render it — so the assertions above
    // mean the field was read, not that the harness rendered an empty page.
    assert.match(withOnion({ url: URL, client_auth: false }), /\.onion/);
});

test('client authorisation is explained beside the URL when it is on (#1853)', () => {
    // The URL alone does not open under client auth, and Tor Browser's failure for a missing key
    // is indistinguishable from the service being down.
    //
    // With the control channel OFF there is no host runner to ask for the key, so naming the host
    // CLI verb is the honest answer. With it ON — which is every appliance — that sentence named a
    // command the reader has no shell to run, and #1882 is exactly that gap; the button below
    // covers that branch.
    const on = withOnion({ url: URL, client_auth: true });
    assert.match(on, /Client authorisation is on/);
    assert.match(on, /onion-client-key/);
    // The WORDS, not the markup. htm strips a whitespace run containing a newline from each end of
    // a static text chunk, so a line break before the <span> renders "to,pithead onion-client-key"
    // — a defect both assertions above stay green on, because each matches one side of the join.
    // This drops the tags and puts NOTHING in their place, which is the load-bearing half: the
    // sibling in xvbview.test.mjs substitutes a space, and a space would re-join "to,<span>pithead"
    // into readable text and pass over the very defect this asserts against. Not a sanitiser — the
    // result is read by assert.match and never reaches a DOM.
    const words = on.split(/<[^>]*>/).join('');
    assert.match(words, /On a machine you can log in to, pithead onion-client-key prints it\./);
    // And is absent when it is off — the same render path, one boolean apart.
    assert.doesNotMatch(withOnion({ url: URL, client_auth: false }), /Client authorisation/);
});

test('the block never carries client-auth key material (#1853)', () => {
    // The container is not given the keys, so this pins the shape rather than the plumbing: a
    // payload that grew a key field would put it on the page, and nothing else would notice.
    const html = withOnion({
        url: URL,
        client_auth: true,
        client_privkey: 'PRIVKEY-SENTINEL',
        client_pubkey: 'PUBKEY-SENTINEL',
    });
    assert.doesNotMatch(html, /SENTINEL/);
});

test('the copy control keeps its name, and the confirmation has its own region (#1853)', () => {
    const html = withOnion({ url: URL, client_auth: false });
    // The button's accessible name IS its text, so the confirmation cannot live in the label: one
    // copy would leave the control named "Copied", a state rather than the action it performs.
    assert.match(
        html,
        /<button type="button" class="btn-range btn-reset">\s*Copy address\s*<\/button>/,
    );
    // The region is rendered EMPTY rather than conditionally: a live region inserted with its
    // message already inside it presents no content change, and announces nothing.
    assert.match(html, /<span role="status"><\/span>/);
});

// The render probe never invokes handlers, so the copy state machine is driven directly. setState
// is replaced rather than stubbed away, so each call's payload is observable in order.
const driveCopy = (clipboard) => {
    const component = new OnionUrl({ onion: { url: URL, client_auth: false } });
    const seen = [];
    component.setState = (patch) => {
        Object.assign(component.state, patch);
        seen.push(patch.copied);
    };
    const priorNavigator = globalThis.navigator;
    Object.defineProperty(globalThis, 'navigator', { value: { clipboard }, configurable: true });
    const restore = () =>
        Object.defineProperty(globalThis, 'navigator', {
            value: priorNavigator,
            configurable: true,
        });
    return { component, seen, restore };
};

test('the confirmation clears itself, so a second copy announces too (#1853)', async (t) => {
    mock.timers.enable({ apis: ['setTimeout'] });
    const { component, seen, restore } = driveCopy({ writeText: async () => {} });
    t.after(() => {
        mock.timers.reset();
        restore();
    });

    await component.copy();
    assert.deepEqual(seen, [true], 'a successful copy raises the confirmation');
    // Left standing, the region's content never changes again and every copy after the first is
    // silent to a screen reader. Coming down is what makes the next one an announcement.
    mock.timers.tick(CLEAR_MS);
    assert.deepEqual(seen, [true, false], 'the confirmation is still up after CLEAR_MS elapsed');
    assert.equal(component.state.copied, false);
});

test('a failed copy takes a standing confirmation down with it (#1853)', async (t) => {
    mock.timers.enable({ apis: ['setTimeout'] });
    const clipboard = { writeText: async () => {} };
    const { component, seen, restore } = driveCopy(clipboard);
    t.after(() => {
        mock.timers.reset();
        restore();
    });

    await component.copy();
    // The clipboard goes away under the operator — a page that lost its secure context, a denied
    // permission. The previous "Copied" must not read as this attempt's answer.
    clipboard.writeText = async () => {
        throw new Error('denied');
    };
    await component.copy();
    assert.deepEqual(seen, [true, false]);
    // And no timer from the failed attempt is left to fire.
    mock.timers.tick(CLEAR_MS);
    assert.deepEqual(seen, [true, false]);
});

test('copyText answers whether the clipboard actually took the text (#1853)', async () => {
    const taken = [];
    assert.equal(await copyText(URL, { writeText: async (t) => taken.push(t) }), true);
    assert.deepEqual(taken, [URL]);
});

test('copyText degrades instead of throwing where there is no clipboard (#1853)', async () => {
    // Not a secure context, or the test renderer: the button has to fall back to "select it by
    // hand", and the label must not claim a copy that never happened.
    assert.equal(await copyText(URL, undefined), false);
    assert.equal(await copyText(URL, {}), false);
    assert.equal(await copyText(URL, { writeText: 'not a function' }), false);
});

test('copyText answers false when the clipboard rejects (#1853)', async () => {
    const rejects = { writeText: async () => { throw new Error('denied'); } };
    assert.equal(await copyText(URL, rejects), false);
});

test('with the control channel on, the note offers the key instead of naming a shell (#1882)', () => {
    // THE DEFECT. On an appliance there is no shell, so "run pithead onion-client-key" describes a
    // door with no handle: the onion is on, published in this very header, and impossible to open.
    const on = withOnion({ url: URL, client_auth: true }, true);
    assert.match(on, /Client authorisation is on/);
    assert.match(on, /Show client key/);
    // The dead sentence must be GONE, not merely joined by a button — a reader who follows it
    // spends their time looking for a prompt this machine does not have.
    assert.doesNotMatch(on, /pithead onion-client-key/);
    // The control, one boolean apart: with the channel off the CLI sentence is still the right
    // answer and must stay. Without this row the assertion above passes on a note that lost both.
    const off = withOnion({ url: URL, client_auth: true }, false);
    assert.match(off, /pithead onion-client-key/);
    assert.doesNotMatch(off, /Show client key/);
});

test('the reveal button is absent when there is no client auth to explain (#1882)', () => {
    // A password-only onion opens from the URL alone. Offering a key there would send the
    // operator looking for something that does not exist.
    assert.doesNotMatch(withOnion({ url: URL, client_auth: false }, true), /Show client key/);
});

test('fetchClientKey POSTs the intent and polls to a terminal result (#1882)', async () => {
    // The container names nothing: no key, no address, no window. It asks, and the host decides.
    const calls = [];
    const realFetch = globalThis.fetch;
    const realTimeout = globalThis.setTimeout;
    globalThis.setTimeout = (cb) => { cb(); return 0; };
    globalThis.fetch = async (url, opts) => {
        calls.push({ url, opts });
        if (url === '/api/control/onion-client-key') {
            return { ok: true, status: 202, json: async () => ({ id: 'ID1' }) };
        }
        return { ok: true, status: 200, json: async () => ({ status: 'applied', client_key: 'K', torrc_line: 'a:descriptor:x25519:K' }) };
    };
    try {
        const kit = await fetchClientKey();
        assert.equal(kit.client_key, 'K');
    } finally {
        globalThis.fetch = realFetch;
        globalThis.setTimeout = realTimeout;
    }
    assert.equal(calls[0].opts.method, 'POST');
    // The CSRF guard the host-side routes require: without the header the route answers 403, so a
    // request that omits it is a reveal that never happens.
    assert.equal(calls[0].opts.headers['X-Pithead-Control'], '1');
    // No body — there is nothing for the container to propose.
    assert.equal(calls[0].opts.body, undefined);
    assert.match(calls[1].url, /^\/api\/control\/result\?id=ID1$/);
});

test('a revealed kit shows both Tor client forms, once, and says so (#1882)', () => {
    // Both forms, because they are for different clients: Tor Browser prompts for the bare key
    // and a system Tor wants the whole line. Guessing which the reader has is how they paste the
    // wrong string into a prompt whose only answer is "invalid".
    const panel = new OnionUrl({ onion: { url: URL, client_auth: true }, enabled: true });
    panel.state = {
        copied: false,
        keyPhase: 'shown',
        kit: { client_key: 'KEYVALUE', torrc_line: 'aaaa:descriptor:x25519:KEYVALUE' },
        keyError: null,
    };
    const html = renderToString(panel.render(panel.props, panel.state));
    assert.match(html, /KEYVALUE/);
    assert.match(html, /aaaa:descriptor:x25519:KEYVALUE/);
    // "Shown once" is the host's behaviour, so the copy has to be an instruction and not a hint.
    assert.match(html, /shown once/);
});

test("a host refusal is surfaced verbatim, not reinterpreted (#1882)", () => {
    // The host knows why there is no key — the onion is off, password-only, or not provisioned
    // yet. A generic client-side "failed" would send the operator to debug Tor instead.
    const panel = new OnionUrl({ onion: { url: URL, client_auth: true }, enabled: true });
    panel.state = { copied: false, keyPhase: 'idle', kit: null, keyError: 'The dashboard onion is not provisioned yet.' };
    const html = renderToString(panel.render(panel.props, panel.state));
    assert.match(html, /not provisioned yet/);
});
