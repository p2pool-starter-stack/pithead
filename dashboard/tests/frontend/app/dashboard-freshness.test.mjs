import assert from 'node:assert/strict';
import { test } from 'node:test';

import { initDashboard } from '../../../mining_dashboard/web/static/dashboard.js';
import {
    GUARD_KEY, RELOAD_GUARD_MS, UPDATED_MESSAGE,
} from '../../../mining_dashboard/web/static/app/freshness.mjs';
import { aborted, httpError, makeEnv, ok } from '../helpers/dashboardenv.mjs';

const at = (version, extra = {}) => ok({ version: { text: version }, ...extra });

test('a changed version shows the notice and reloads once, on the poll that noticed', async () => {
    const t = makeEnv({ responses: [at('v1'), at('v1'), at('v2'), at('v2')] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    await d.tick();
    assert.equal(t.reloads.length, 0);
    assert.equal(t.last().reloading, null);
    await d.tick();
    assert.equal(t.reloads.length, 1);
    assert.equal(t.last().reloading, UPDATED_MESSAGE);
    await d.tick();
    assert.equal(t.reloads.length, 1);
    assert.ok(Number(t.session[GUARD_KEY]) > 0);
});

test('the same version across many polls never reloads', async () => {
    const t = makeEnv({ responses: Array.from({ length: 6 }, () => at('v1')) });
    const d = initDashboard(t.env);
    await d.firstLoad;
    for (let i = 0; i < 5; i++) await d.tick();
    assert.equal(t.reloads.length, 0);
    assert.equal(t.last().reloading, null);
});

test('failing polls keep the banner and never reload; the first good poll reloads exactly once', async () => {
    const t = makeEnv({ responses: [at('v1'), aborted(), httpError(502), aborted(), at('v1'), at('v1')] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    for (let i = 0; i < 3; i++) {
        await d.tick();
        assert.equal(t.last().connected, false);
        assert.equal(t.reloads.length, 0);
        assert.equal(t.last().reloading, null);
    }
    await d.tick();
    assert.equal(t.reloads.length, 1);
    assert.equal(t.last().reloading, UPDATED_MESSAGE);
    await d.tick();
    assert.equal(t.reloads.length, 1);
});

test('a trigger inside the two-minute window shows the notice without reloading, and polling still paints', async () => {
    const recent = String(Date.now() - RELOAD_GUARD_MS / 2);
    const t = makeEnv({
        session: { [GUARD_KEY]: recent },
        responses: [at('v1', { n: 1 }), at('v2', { n: 2 }), at('v2', { n: 3 })],
    });
    const d = initDashboard(t.env);
    await d.firstLoad;
    await d.tick();
    assert.equal(t.reloads.length, 0);
    assert.equal(t.last().reloading, UPDATED_MESSAGE);
    assert.equal(t.last().state.n, 2);
    await d.tick();
    assert.equal(t.reloads.length, 0);
    assert.equal(t.last().state.n, 3);
    assert.equal(t.session[GUARD_KEY], recent);
});

test('a trigger after the window has passed reloads and records the time', async () => {
    const old = String(Date.now() - RELOAD_GUARD_MS - 1000);
    const t = makeEnv({ session: { [GUARD_KEY]: old }, responses: [at('v1'), at('v2')] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    await d.tick();
    assert.equal(t.reloads.length, 1);
    assert.notEqual(t.session[GUARD_KEY], old);
});

test('focus and visibility each run one extra poll through the in-flight guard; hiding does not', async () => {
    const t = makeEnv({ responses: [at('v1'), at('v1'), at('v1')] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    assert.equal(t.windowHandlers.length, 1);
    const fire = t.windowHandlers[0];
    t.doc.visibilityState = 'hidden';
    fire();
    assert.equal(t.fetches.length, 1);
    t.doc.visibilityState = 'visible';
    const first = fire();
    fire();
    await new Promise((r) => setImmediate(r));
    assert.equal(t.fetches.length, 2);
    await first;
    await d.tick();
    assert.equal(t.fetches.length, 3);
});
