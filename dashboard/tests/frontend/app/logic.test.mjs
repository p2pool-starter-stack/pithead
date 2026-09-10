import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sortWorkers, fmtTimestamp, WORKER_COLUMNS, THEMES, THEME_ORDER, normalizeTheme, clampZoomWindow, fmtWindowDuration, SERIES_KEYS, normalizeSeries, normalizeChoice, normalizeSort, loadPref, savePref, AVG_WINDOWS, DEFAULT_AVG_WINDOW, normalizeAvgWindow, formatAgo } from '../../../mining_dashboard/web/static/app/logic.mjs';

const col = (key) => WORKER_COLUMNS.findIndex((c) => c.key === key);

test('sortWorkers: null index keeps the server-provided order', () => {
    const ws = [{ name: 'b' }, { name: 'a' }];
    assert.deepEqual(sortWorkers(ws, null, true), ws);
});

test('sortWorkers: numeric columns sort numerically, not lexically', () => {
    // The whole reason the server sends raw ip_sort/h* numbers: a string sort would order
    // 1000 before 9. This is the regression this suite exists to catch.
    const ws = [{ ip_sort: 9 }, { ip_sort: 1000 }, { ip_sort: 100 }];
    assert.deepEqual(
        sortWorkers(ws, col('ip_sort'), true).map((w) => w.ip_sort),
        [9, 100, 1000],
    );
});

test('sortWorkers: hashrate column also sorts numerically', () => {
    const ws = [{ h15: 5000 }, { h15: 250 }, { h15: 12000 }];
    assert.deepEqual(
        sortWorkers(ws, col('h15'), true).map((w) => w.h15),
        [250, 5000, 12000],
    );
});

test('sortWorkers: descending reverses the order', () => {
    const ws = [{ ip_sort: 1 }, { ip_sort: 2 }, { ip_sort: 3 }];
    assert.deepEqual(
        sortWorkers(ws, col('ip_sort'), false).map((w) => w.ip_sort),
        [3, 2, 1],
    );
});

test('sortWorkers: name column sorts as text', () => {
    const ws = [{ name: 'rig-10' }, { name: 'rig-2' }, { name: 'rig-1' }];
    assert.deepEqual(
        sortWorkers(ws, col('name'), true).map((w) => w.name),
        ['rig-1', 'rig-10', 'rig-2'],   // lexical (not natural) ordering, as implemented
    );
});

test('sortWorkers: does not mutate the input array', () => {
    const ws = [{ ip_sort: 3 }, { ip_sort: 1 }, { ip_sort: 2 }];
    const before = ws.map((w) => w.ip_sort);
    sortWorkers(ws, col('ip_sort'), true);
    assert.deepEqual(ws.map((w) => w.ip_sort), before);
});

test('WORKER_COLUMNS: keys match the worker fields the server sends', () => {
    assert.deepEqual(
        WORKER_COLUMNS.map((c) => c.key),
        ['name', 'ip_sort', 'uptime', 'h60', 'h15', 'accepted', 'rejected'],
    );
});

test('WORKER_COLUMNS: hashrate windows are labelled by what the data is (#387)', () => {
    // h60 holds the 1m rate and h15 the 10m rate (legacy key names; see data_service). The labels
    // must say 1m / 10m so the table matches the chart toggle and Telegram's "(10m avg)".
    const labels = Object.fromEntries(WORKER_COLUMNS.map((c) => [c.key, c.label]));
    assert.equal(labels.h60, '1m');
    assert.equal(labels.h15, '10m');
    assert.equal(labels.h10, undefined); // dropped — via the proxy it duplicated the 1m rate
});

test('sortWorkers: rejected column sorts numerically (find problem rigs)', () => {
    // Per-worker share counts are raw numbers so the operator can sort the worst rejecters up.
    const ws = [{ rejected: 12 }, { rejected: 0 }, { rejected: 3 }];
    assert.deepEqual(
        sortWorkers(ws, col('rejected'), false).map((w) => w.rejected),
        [12, 3, 0],
    );
});

test('fmtTimestamp: returns a non-empty string for an epoch-ms value', () => {
    // Exact text is locale/timezone dependent (CI varies), so assert shape, not content.
    const out = fmtTimestamp(0);
    assert.equal(typeof out, 'string');
    assert.ok(out.length > 0);
});

test('normalizeTheme: passes valid modes through, defaults the rest to auto', () => {
    for (const t of THEMES) assert.equal(normalizeTheme(t), t);
    assert.equal(normalizeTheme(null), 'auto');       // nothing saved yet
    assert.equal(normalizeTheme('sepia'), 'auto');    // garbage in localStorage
});

test('THEME_ORDER: the control renders every theme exactly once', () => {
    // The segmented control maps over THEME_ORDER, so it must cover the same set as THEMES with
    // no dupes/strays — otherwise a mode would be unreachable or rendered twice.
    assert.deepEqual([...THEME_ORDER].sort(), [...THEMES].sort());
});

test('normalizeAvgWindow: passes valid windows through, defaults the rest to 10m (#168)', () => {
    for (const w of AVG_WINDOWS) assert.equal(normalizeAvgWindow(w), w);
    assert.equal(normalizeAvgWindow(null), '10m');     // nothing saved yet
    assert.equal(normalizeAvgWindow('7d'), '10m');     // garbage in localStorage
    assert.equal(normalizeAvgWindow(undefined), '10m');
    assert.equal(DEFAULT_AVG_WINDOW, '10m');           // the default is today's headline series
});

test('AVG_WINDOWS: the client window set matches the server contract (#168)', () => {
    // The buttons (chart.mjs WINDOWS) and the server (config.HASHRATE_WINDOWS) must agree on the
    // same five keys in the same order, or a button would request a window the server canonicalizes
    // away (silently snapping back to 10m).
    assert.deepEqual(AVG_WINDOWS, ['1m', '10m', '1h', '12h', '24h']);
});

// --- Issue #47: zoom window helpers --------------------------------------------------

test('clampZoomWindow: orders endpoints and enforces a minimum span', () => {
    // Reversed drag is normalized low->high.
    assert.deepEqual(clampZoomWindow(2000, 1000, 100), { from: 1000, to: 2000 });
    // A too-narrow window is widened around its centre to minSpanMs.
    assert.deepEqual(clampZoomWindow(1000, 1010, 100), { from: 955, to: 1055 });
    // A comfortably wide window is left as-is.
    assert.deepEqual(clampZoomWindow(0, 5000, 1000), { from: 0, to: 5000 });
});

test('clampZoomWindow: rejects unusable input', () => {
    assert.equal(clampZoomWindow(NaN, 1000, 100), null);
    assert.equal(clampZoomWindow(1000, 1000, 100), null);   // zero-width selection
    assert.equal(clampZoomWindow(Infinity, 1, 100), null);
});

test('fmtWindowDuration: two coarsest units, trailing zeros dropped', () => {
    assert.equal(fmtWindowDuration(0), '0s');
    assert.equal(fmtWindowDuration(45_000), '45s');
    assert.equal(fmtWindowDuration(90_000), '1m 30s');
    assert.equal(fmtWindowDuration(3_600_000), '1h');          // exactly 1h -> no "0m"
    assert.equal(fmtWindowDuration(4_800_000), '1h 20m');
    assert.equal(fmtWindowDuration(3 * 86_400_000), '3d');     // exactly 3d -> no "0h"
});

test('normalizeSeries: defaults every series to visible, only explicit false hides', () => {
    const allOn = { p2pool: true, xvb: true, shares: true, events: true, raffle: true, payouts: true, xvb_donation: true };
    assert.deepEqual(normalizeSeries(null), allOn);
    assert.deepEqual(normalizeSeries({}), allOn);
    assert.deepEqual(normalizeSeries({ xvb: false }), { ...allOn, xvb: false });
    // Marker datasets (#652) toggle like the line series.
    assert.deepEqual(normalizeSeries({ events: false, raffle: false }), { ...allOn, events: false, raffle: false });
    // Garbage / stray keys are ignored; output is always the full key set.
    assert.deepEqual(Object.keys(normalizeSeries({ junk: 1 })).sort(), [...SERIES_KEYS].sort());
    assert.deepEqual(normalizeSeries('nope'), allOn);
});

test('formatAgo: relative "N ago" for a unix-seconds timestamp, "Never" when unset (#381)', () => {
    const now = 1_000_000_000_000; // fixed nowMs
    assert.equal(formatAgo(0, now), 'Never');            // no payout yet
    assert.equal(formatAgo(null, now), 'Never');
    assert.equal(formatAgo(now / 1000 - 3600, now), '1h ago');   // 1h before now
    assert.equal(formatAgo(now / 1000 - 90, now), '1m 30s ago');
    assert.equal(formatAgo(now / 1000 + 60, now), 'just now');   // future ts (clock skew)
});

// --- Issue #658: persisted single-choice UI preferences --------------------------------

test('normalizeChoice: allowed values pass, anything else falls back', () => {
    assert.equal(normalizeChoice('json', ['form', 'json'], 'form'), 'json');
    assert.equal(normalizeChoice('garbage', ['form', 'json'], 'form'), 'form');
    assert.equal(normalizeChoice(null, ['form', 'json'], 'form'), 'form');
});

test('normalizeSort: round-trips a valid choice, rejects garbage and stale columns', () => {
    assert.deepEqual(normalizeSort('2:desc', 10), { sortIndex: 2, sortAsc: false });
    assert.deepEqual(normalizeSort('0:asc', 10), { sortIndex: 0, sortAsc: true });
    // A column index that no longer exists (column removed) → server order.
    assert.deepEqual(normalizeSort('99:asc', 10), { sortIndex: null, sortAsc: true });
    for (const bad of [null, '', 'x:asc', '1:up', '-1:asc']) {
        assert.deepEqual(normalizeSort(bad, 10), { sortIndex: null, sortAsc: true }, `raw: ${bad}`);
    }
});

test('loadPref/savePref: no localStorage (node) means fallback and no throw', () => {
    // Under node --test there is no localStorage — the guards must make these safe, because
    // components call them from constructors and the render tests import those components.
    assert.equal(loadPref('anyKey', ['a', 'b'], 'a'), 'a');
    assert.doesNotThrow(() => savePref('anyKey', 'b'));
});
