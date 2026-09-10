import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WORKER_COLUMNS } from '../../../mining_dashboard/web/static/app/logic.mjs';
import { clone, renderApp, UI } from '../harness.mjs';

// --- Workers table ----------------------------------------------------------------------

test('WorkersTable renders headers and a row per worker with status classes', () => {
    const html = renderApp();
    for (const label of ['Worker', 'IP', 'Uptime', 'Accepted', 'Rejected']) {
        assert.match(html, new RegExp(`>${label}<`), `missing column: ${label}`);
    }
    assert.match(html, /rig-alpha/);
    assert.match(html, /rig-bravo/);
    assert.match(html, /status-ok/); // the online worker's row
    assert.match(html, /status-bad/); // the offline worker's row
    assert.match(html, /badge-ok">P2Pool/); // PoolBadge for a p2pool worker
});

test('WorkersTable marks the sorted column, visibly and via aria-sort (#656)', () => {
    // No sort chosen (server order): no column claims a direction.
    assert.doesNotMatch(renderApp(), /aria-sort/);
    const asc = renderApp({ ui: { ...UI, sortIndex: 0, sortAsc: true } });
    assert.match(asc, /<th[^>]*class="sorted"[^>]*aria-sort="ascending"[^>]*><button[^>]*>Worker<span class="sort-arrow"> ▲<\/span>/);
    const desc = renderApp({ ui: { ...UI, sortIndex: 0, sortAsc: false } });
    assert.match(desc, /aria-sort="descending"[^>]*><button[^>]*>Worker<span class="sort-arrow"> ▼<\/span>/);
});

test('WorkersTable sort headers are real buttons, so keyboard can sort (#671)', () => {
    // A native <button> is focusable and activates on Enter/Space, firing the same onClick
    // (onSort) path the mouse takes — keyboard operability rides on the element choice, so
    // the component-tier assertion is that every header's click target IS a native button.
    const html = renderApp();
    const btns = html.match(/<button type="button" class="th-sort-btn" title="Sort by /g) || [];
    assert.equal(btns.length, WORKER_COLUMNS.length);
    assert.match(html, /<th><button type="button" class="th-sort-btn" title="Sort by Worker">Worker</);
});

test('WorkersTable with no workers shows the connect hint instead of a bare table (#385)', () => {
    // The fixture's host_ip is "Unknown Host" — the hint must fall back to the docs placeholder.
    const s = clone();
    s.workers = [];
    const html = renderApp({ state: s });
    assert.match(html, /Workers Alive/);
    assert.match(html, /No workers connected yet/);
    assert.match(html, /YOUR_STACK_IP:3333/);
    assert.match(html, /docs\/workers\.md/); // links the workers guide
    assert.doesNotMatch(html, /workers-table/); // no empty table skeleton
    assert.doesNotMatch(html, /rig-alpha/);
});

test('WorkersTable connect hint uses the real host IP when known (#385)', () => {
    const s = clone();
    s.workers = [];
    s.host_ip = '192.168.1.10';
    const html = renderApp({ state: s });
    assert.match(html, /192\.168\.1\.10:3333/);
    assert.doesNotMatch(html, /Unknown Host:3333/);
    // A custom p2pool.stratum_port (#172) flows into the hint — the UI never lies about where
    // rigs must point.
    const custom = clone();
    custom.workers = [];
    custom.host_ip = '192.168.1.10';
    custom.stratum_port = 4444;
    assert.match(renderApp({ state: custom }), /192\.168\.1\.10:4444/);
    // A populated fleet — even all-offline — keeps the table, never the hint.
    const offline = clone();
    offline.workers = offline.workers.map((w) => ({ ...w, status: 'offline' }));
    assert.doesNotMatch(renderApp({ state: offline }), /No workers connected yet/);
});

test('ProxyTotals footer is hidden until the proxy reports data', () => {
    assert.doesNotMatch(renderApp(), /Proxy totals/); // fixture has has_data:false
    const s = clone();
    s.proxy_summary.has_data = true;
    s.proxy_summary.accepted = '1200';
    assert.match(renderApp({ state: s }), /Proxy totals/);
});

test('ProxyTotals reddens the rejected figure only when reject_level is high', () => {
    // The base fixture's workers are all clean, so nothing reaches the styled-rejects branch.
    const s = clone();
    Object.assign(s.proxy_summary, {
        has_data: true, accepted: '1200', rejected: '50', reject_pct: '4%',
        reject_level: 'high', invalid: '0', best: '123',
    });
    assert.match(renderApp({ state: s }), /status-bad">50/); // high -> rejected total is reddened
    s.proxy_summary.reject_level = 'ok';
    assert.doesNotMatch(renderApp({ state: s }), /status-bad">50/); // ok -> plain, not reddened
});

test('WorkersTable surfaces the per-rig api-unreadable and reject badges, and the pool badge variants', () => {
    // The single fixture pins both workers to pool=p2pool, api_ok=null, reject_flag=null, so these
    // three problem-rig signals — the whole point of the pool/api/rejected columns — never render.
    const s = clone();
    Object.assign(s.workers[0], { api_ok: false, adopted: true }); // adopted rig, dead feed
    s.workers[0].reject_flag = { text: '90% rejected', title: 'high reject rate' };
    s.workers[0].pool = 'xvb'; // purple XvB badge
    s.workers[1].pool = 'somethingelse'; // unrecognised -> Unknown (bad) badge
    const html = renderApp({ state: s });
    assert.match(html, /api ⚠/); // api_ok===false badge (only UI signal a rig's API is unreadable)
    assert.match(html, /90% rejected/); // per-row reject badge (how you spot a problem rig)
    assert.match(html, /badge-purple">XvB/);
    assert.match(html, /badge-bad">Unknown/);
});

test('WorkersTable renders the RigForge version badge + chips when present, nothing when absent (#235)', () => {
    // A plain-xmrig worker has no `rigforge` (the server sends null) -> no chips, no error.
    const plain = clone();
    plain.workers.forEach((w) => (w.rigforge = null));
    const plainHtml = renderApp({ state: plain });
    assert.doesNotMatch(plainHtml, /rf 1\.7\.0/);
    assert.doesNotMatch(plainHtml, /throttling/);

    // A RigForge worker carries the server-built {version, chips} view.
    const rf = clone();
    rf.workers[0].rigforge = {
        version: '1.7.0',
        miner_down: false,
        chips: [
            { text: 'throttling', variant: 'bad', title: 'hot' },
            { text: 'gov: performance', variant: 'ok', title: '' },
            { text: '142 W · 86.9 H/s·W', variant: 'outline', title: 'power' },
        ],
    };
    rf.workers[1].rigforge = null; // the other rig is plain xmrig
    const html = renderApp({ state: rf });
    assert.match(html, /rf 1\.7\.0/); // version badge
    assert.match(html, /badge-bad" title="hot">throttling/); // a bad chip
    assert.match(html, /gov: performance/);
    assert.match(html, /142 W · 86.9 H\/s·W/);
});

test('WorkersTable badges a rig running an older RigForge — and only that rig (#596)', () => {
    const s = clone();
    s.workers[0].rigforge_update = { available: true, latest: 'v1.11.2', url: 'https://h/v1.11.2' };
    s.workers[1].rigforge_update = null; // current / plain-xmrig rig -> no badge
    const html = renderApp({ state: s });
    assert.match(html, /rf v1\.11\.2 available/); // the accent callout renders
    assert.match(html, /A newer RigForge release is available: v1\.11\.2/); // tooltip
    assert.equal(html.match(/rf v1\.11\.2 available/g).length, 1); // exactly one rig badged

    const none = clone();
    none.workers.forEach((w) => (w.rigforge_update = null));
    assert.doesNotMatch(renderApp({ state: none }), /RigForge release is available/);
});
