import { test } from 'node:test';
import assert from 'node:assert/strict';
import { StatsTable } from '../../../mining_dashboard/web/static/workers/workerview.mjs';
import { render } from '../helpers/render.mjs';
import { clone, renderApp, UI } from '../harness.mjs';

// --- Worker Inspect (#185) ---------------------------------------------------------------

test('worker names are inspect buttons only when the control channel is on (#185)', () => {
    // Control off (base fixture): the name is plain text, no inspect affordance.
    const off = renderApp();
    assert.doesNotMatch(off, /worker-name-link/);
    // Control on: each worker name becomes an inspect button.
    const s = clone();
    s.control_enabled = true;
    const on = renderApp({ state: s });
    assert.match(on, /worker-name-link/);
    assert.match(on, />rig-alpha</);
});

test('WorkerInspect dialog renders for the selected worker (#185, native <dialog> since #518)', () => {
    const s = clone();
    s.control_enabled = true;
    // ui.inspectWorker drives the dialog; the render harness runs no effects (no showModal()),
    // so it's the pre-fetch loading state (the fetch itself is covered by the server tests).
    const html = renderApp({ state: s, ui: { ...UI, inspectWorker: 'rig-alpha' } });
    assert.match(html, /<dialog class="worker-inspect/);
    assert.match(html, /Worker · rig-alpha/);
    assert.match(html, /Loading/);
});

test('no WorkerInspect dialog when none is selected (#185)', () => {
    const s = clone();
    s.control_enabled = true;
    assert.doesNotMatch(renderApp({ state: s }), /<dialog class="worker-inspect/);
});

test('StatsTable renders the enriched feed as a label/value table, colouring warn/bad values (#507)', () => {
    // The detail view swaps the compact list's badge row for a table: label cell + value cell,
    // driven by the server-built {label, value, variant, title} stats. warn/bad colour the value.
    const html = render(StatsTable, {
        stats: [
            { label: 'Governor', value: 'powersave', variant: 'warn', title: 'CPU governor' },
            { label: 'HugePages', value: '1280', variant: 'outline', title: '' },
            { label: 'CPU', value: 'throttling', variant: 'bad', title: 'hot' },
        ],
    });
    assert.match(html, /class="worker-history"/); // reuses the existing detail-table styling
    assert.doesNotMatch(html, /badge-row/); // NOT the compact list's badge row
    assert.match(html, /Governor<\/td>/);
    assert.match(html, /class="stat-value status-warn">powersave/); // warn colours its value
    assert.match(html, /class="stat-value status-bad">throttling/); // bad colours its value
    assert.match(html, /<td class="stat-value">1280/); // outline metric stays plain
});

test('StatsTable renders nothing when a rig reports no metrics (#507)', () => {
    assert.equal(render(StatsTable, { stats: [] }), '');
    assert.equal(render(StatsTable, { stats: undefined }), '');
});
