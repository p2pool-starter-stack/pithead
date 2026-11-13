import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
    createFreshness, GUARD_KEY, holdWhile, installFreshness, releaseAutoReload, holdAutoReload,
    reportPageStale, RELOAD_GUARD_MS, STALE_MESSAGE, UPDATED_MESSAGE,
} from '../../../mining_dashboard/web/static/app/freshness.mjs';

function make({ responses = [], session = {}, clock = 1e12 } = {}) {
    const reloads = [];
    const polls = [];
    const changes = [];
    const deps = {
        reload: () => reloads.push(1),
        store: {
            getItem: (k) => (k in session ? session[k] : null),
            setItem: (k, v) => { session[k] = String(v); },
        },
        fetchFn: async (url) => {
            polls.push(url);
            const next = responses.shift();
            if (next instanceof Error) throw next;
            return { ok: next !== false };
        },
        now: () => clock,
        sleep: async () => {},
        onChange: () => changes.push(1),
    };
    return { f: createFreshness(deps), deps, reloads, polls, changes, session };
}

test('reportPageStale shows its message, polls /api/state, and reloads only after an ok answer', async () => {
    const t = make({ responses: [new TypeError('down'), false, true] });
    await t.f.reportPageStale();
    assert.equal(t.f.message(), STALE_MESSAGE);
    assert.deepEqual(t.polls, ['/api/state?range=1h', '/api/state?range=1h', '/api/state?range=1h']);
    assert.equal(t.reloads.length, 1);
});

test('reportPageStale never reloads while the server stays unreachable', async () => {
    const t = make({ responses: Array.from({ length: 400 }, () => new TypeError('down')) });
    await t.f.reportPageStale();
    assert.equal(t.reloads.length, 0);
    assert.equal(t.f.message(), STALE_MESSAGE);
});

test('concurrent reportPageStale calls share one reconnect loop', async () => {
    const t = make({ responses: [true] });
    await Promise.all([t.f.reportPageStale(), t.f.reportPageStale()]);
    assert.equal(t.polls.length, 1);
    assert.equal(t.reloads.length, 1);
});

test('a held reload waits for release, then fires once', async () => {
    const t = make();
    t.f.hold();
    t.f.goodPoll('v1', false);
    t.f.goodPoll('v2', false);
    assert.equal(t.f.message(), UPDATED_MESSAGE);
    assert.equal(t.reloads.length, 0);
    t.f.release();
    assert.equal(t.reloads.length, 1);
    t.f.release();
    assert.equal(t.reloads.length, 1);
});

test('release without a pending reload does nothing; two holds need two releases', () => {
    const t = make();
    t.f.hold();
    t.f.release();
    assert.equal(t.reloads.length, 0);
    t.f.hold();
    t.f.hold();
    t.f.goodPoll('v1', false);
    t.f.goodPoll('v2', false);
    t.f.release();
    assert.equal(t.reloads.length, 0);
    t.f.release();
    assert.equal(t.reloads.length, 1);
});

test('the guard blocks a second reload inside the window and allows it after', async () => {
    const t = make({ responses: [true, true] });
    await t.f.reportPageStale();
    assert.equal(t.reloads.length, 1);
    assert.equal(t.session[GUARD_KEY], '1000000000000');
    const again = createFreshness({ ...t.deps, now: () => 1e12 + RELOAD_GUARD_MS - 1 });
    again.goodPoll('v1', true);
    assert.equal(t.reloads.length, 1);
    assert.equal(again.message(), UPDATED_MESSAGE);
    const later = createFreshness({ ...t.deps, now: () => 1e12 + RELOAD_GUARD_MS });
    later.goodPoll('v1', true);
    assert.equal(t.reloads.length, 2);
});

test('unreadable or unwritable storage still reloads, once per page', () => {
    const t = make();
    const broken = {
        getItem: () => { throw new Error('denied'); },
        setItem: () => { throw new Error('denied'); },
    };
    const f = createFreshness({ ...t.deps, store: broken });
    f.goodPoll('v1', false);
    f.goodPoll('v2', false);
    f.goodPoll('v2', false);
    assert.equal(f.message(), UPDATED_MESSAGE);
    assert.equal(t.reloads.length, 1);
});

test('a guard-blocked reportPageStale keeps polling and reloads when the window has passed', async () => {
    let clock = 1e12;
    const t = make({ responses: Array.from({ length: 200 }, () => true), session: { [GUARD_KEY]: String(clock - 1000) } });
    const f = createFreshness({
        ...t.deps,
        now: () => clock,
        sleep: async () => { clock += 10000; },
    });
    await f.reportPageStale();
    assert.equal(t.reloads.length, 1);
    assert.ok(t.polls.length > 5);
    assert.ok(clock - 1e12 >= RELOAD_GUARD_MS - 1000);
});

test('the first version is remembered and a missing version never triggers', () => {
    const t = make();
    t.f.goodPoll(undefined, false);
    t.f.goodPoll('v1', false);
    t.f.goodPoll(undefined, false);
    t.f.goodPoll('v1', false);
    assert.equal(t.reloads.length, 0);
    assert.equal(t.f.message(), null);
    assert.equal(t.changes.length, 0);
});

test('the module-level functions drive the installed instance; holdWhile is edge-triggered', async () => {
    const t = make({ responses: [true] });
    installFreshness(t.deps);
    const owner = {};
    holdWhile(owner, true);
    holdWhile(owner, true);
    await reportPageStale();
    assert.equal(t.reloads.length, 0);
    holdWhile(owner, false);
    holdWhile(owner, false);
    assert.equal(t.reloads.length, 1);
    holdAutoReload();
    releaseAutoReload();
});
