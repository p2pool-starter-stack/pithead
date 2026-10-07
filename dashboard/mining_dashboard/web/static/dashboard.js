// Dashboard entry point (ES module, loaded from <head>).
//
// Owns the small amount of client state and the refresh loop, then renders the Preact <App>.
// Data comes from GET /api/state (the server builds it; see views.build_state); the client
// holds only *UI* state that must survive data refreshes — selected range, table sort, and
// the simple/advanced view — plus the latest data snapshot and connection status.
//
// Everything runs inside initDashboard(), whose parameters name the browser seams (DOM, storage,
// fetch, history, timer, render) with real defaults. The browser boot at the bottom is guarded on
// `document`, so `node --test` can import this file with no DOM and drive the loop through fakes
// (#903, tests/frontend/dashboard.test.mjs).

import { App } from "./app/components.mjs";
import {
  normalizeAvgWindow,
  normalizeSeries,
  normalizeSort,
  normalizeTheme,
  savePref,
  WORKER_COLUMNS,
} from "./app/logic.mjs";
import { html, render } from "./app/preact.mjs";
import { SovereignApp } from "./sovereign/app.mjs";

export const REFRESH_MS = 30000;
// Abort a poll that hasn't answered before the next tick would fire. Without this a hung
// connection (a dropped Tor circuit hangs rather than fails) never rejects, and the `inflight`
// guard then blocks every later tick — the page freezes on stale data with no banner (#382).
// Derived from REFRESH_MS so the two can't drift apart; far above a healthy Tor round-trip,
// so it only trips on dead links.
export const FETCH_TIMEOUT_MS = REFRESH_MS - 5000;
const CHART_RANGES = new Set(["1h", "24h", "1w", "1m", "all"]);

function normalizeRange(range) {
  return CHART_RANGES.has(range) ? range : "all";
}

// A manual-zoom window {from, to} (epoch seconds) read from ?from=&to= so a zoomed URL is
// shareable and survives reload (Issue #47); null/garbage falls back to the preset range.
export function windowFromUrl(params) {
  const from = parseFloat(params.get("from"));
  const to = parseFloat(params.get("to"));
  return Number.isFinite(from) && Number.isFinite(to) && from > 0 && to > from
    ? { from, to }
    : null;
}

// Which chart series are shown — persisted so a hidden series stays hidden across reloads.
// Takes the raw localStorage string; garbage (or nothing) falls back to all-visible.
export function loadSeries(raw) {
  try {
    return normalizeSeries(JSON.parse(raw));
  } catch {
    return normalizeSeries(null);
  }
}

export function initDashboard({
  doc = document,
  storage = localStorage,
  href = location.href,
  fetchFn = (url, opts) => fetch(url, opts),
  replaceUrl = (url) => history.replaceState(null, "", url),
  schedule = (fn, ms) => setInterval(fn, ms),
  listen = (name, fn) => globalThis.addEventListener?.(name, fn),
  currentHref = () => globalThis.location?.href || href,
  renderApp = null,
} = {}) {
  const root = doc.getElementById("app");
  if (root && !renderApp) root.replaceChildren();
  const pageUrl = new URL(href);
  const path = pageUrl.pathname;
  const params = pageUrl.searchParams;
  const sovereign = params.get("ui") === "sovereign";
  const Root = sovereign ? SovereignApp : App;
  doc.documentElement.setAttribute("data-ui", sovereign ? "sovereign" : "classic");

  const ui = {
    range: normalizeRange(params.get("range")),
    window: windowFromUrl(params), // {from,to} epoch-s when zoomed, else null
    series: loadSeries(storage.getItem("dashboardSeries")), // booleans per SERIES_KEYS (Issue #47)
    // Hashrate-averaging window the chart plots (#168); persisted, default 10m (today's series).
    avg: normalizeAvgWindow(storage.getItem("dashboardAvgWindow")),
    // Workers-table sort (#658); persisted like the other view preferences.
    ...normalizeSort(storage.getItem("dashboardSort"), WORKER_COLUMNS.length),
    view: ["advanced", "config", "backup"].includes(storage.getItem("dashboardView"))
      ? storage.getItem("dashboardView")
      : "simple",
    // Theme is persisted in localStorage so it survives reloads and stack restarts (Issue #43).
    // theme-init.js already applied it to <html> before first paint; we mirror it into the UI
    // state and re-apply on toggle.
    theme: normalizeTheme(storage.getItem("dashboardTheme")),
    // Simple-view pointer to the Advanced-only earnings/XvB calculators (#425). Persisted once
    // dismissed — either explicitly or by visiting Advanced view — so it shows once per browser.
    hintDismissed: storage.getItem("dashboardCalcHint") === "dismissed",
    // Worker Inspect (#185): the name of the worker whose panel is open, or null. Transient UI —
    // not persisted; the panel fetches its own /api/worker detail on open.
    inspectWorker: null,
  };

  // Reflect the current theme onto <html data-theme>; the CSS palette (and the chart, which reads
  // the resolved CSS variables) follow from there.
  function applyTheme(theme) {
    doc.documentElement.setAttribute("data-theme", theme);
  }

  let state = null; // latest /api/state payload, or null before the first response
  let connected = true; // false after a failed fetch (we keep showing the last snapshot)
  let inflight = null; // one shared promise prevents overlapping fetches
  let queued = false; // a UI change during a poll must fetch its latest query once that poll ends
  let revision = 0; // stale responses must not paint beneath newer range controls

  // Tests inject renderApp to observe exactly what the App would receive; the browser default
  // renders the real <App> with the same props.
  const paint =
    renderApp ??
    ((p) =>
      render(
        html`<${Root} state=${p.state} connected=${p.connected} ui=${p.ui}
                     onRange=${p.onRange} onSort=${p.onSort} onView=${p.onView} onTheme=${p.onTheme}
                     onZoom=${p.onZoom} onResetZoom=${p.onResetZoom} onToggleSeries=${p.onToggleSeries}
                     onAvgWindow=${p.onAvgWindow} onDismissHint=${p.onDismissHint}
                     onInspect=${p.onInspect} onCloseInspect=${p.onCloseInspect} onRetry=${p.onRetry} />`,
        root,
      ));

  function rerender() {
    paint({
      state,
      connected,
      ui,
      onRange: setRange,
      onSort,
      onView: setView,
      onTheme: setTheme,
      onZoom: setZoom,
      onResetZoom: resetZoom,
      onToggleSeries: toggleSeries,
      onAvgWindow: setAvgWindow,
      onDismissHint: dismissHint,
      onInspect: openInspect,
      onCloseInspect: closeInspect,
      onRetry: refresh,
    });
  }

  // Worker Inspect (#185): open/close the per-worker panel. Not persisted — transient UI state.
  function openInspect(name) {
    ui.inspectWorker = name;
    rerender();
  }
  function closeInspect() {
    ui.inspectWorker = null;
    rerender();
  }

  async function poll() {
    const pollRevision = revision;
    try {
      // A custom zoom window overrides the preset range; the server adapts resolution to it. The
      // averaging window (#168) applies to both — the server selects which window's columns to plot.
      const base = ui.window
        ? "from=" + ui.window.from + "&to=" + ui.window.to
        : "range=" + encodeURIComponent(ui.range);
      const qs = base + "&avg=" + encodeURIComponent(ui.avg);
      const res = await fetchFn("/api/state?" + qs, {
        headers: { "X-Requested-With": "fetch" },
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      });
      if (!res.ok) throw new Error("HTTP " + res.status);
      const nextState = await res.json();
      if (pollRevision === revision) {
        state = nextState;
        connected = true;
        if (state.page_title) doc.title = state.page_title;
      }
    } catch (e) {
      if (pollRevision === revision) {
        connected = false;
        console.warn("dashboard refresh failed", e);
      }
    } finally {
      if (pollRevision === revision) rerender();
    }
  }

  async function drain() {
    do {
      queued = false;
      await poll();
    } while (queued);
  }

  function tick() {
    if (inflight) return;
    inflight = drain().finally(() => (inflight = null));
    return inflight;
  }

  function refresh() {
    revision += 1;
    queued = true;
    return inflight || tick();
  }

  function replaceChartUrl(query) {
    if (!sovereign) return replaceUrl(query ? `?${query}` : path);
    const next = new URL(currentHref());
    for (const key of ["range", "from", "to"]) next.searchParams.delete(key);
    for (const [key, value] of new URLSearchParams(query)) next.searchParams.set(key, value);
    replaceUrl(next.pathname + next.search + next.hash);
  }

  function setRange(r) {
    ui.range = normalizeRange(r);
    ui.window = null; // picking a preset exits any manual zoom
    replaceChartUrl(ui.range === "all" ? "" : "range=" + encodeURIComponent(ui.range));
    return refresh(); // re-fetch immediately; the chart/series depend on the range
  }

  // Called (debounced) by the chart when a zoom/pan gesture settles: pin the visible window and
  // refetch it from the server at duration-adaptive resolution (Issue #47).
  function setZoom(fromS, toS) {
    ui.window = { from: fromS, to: toS };
    replaceChartUrl("from=" + Math.round(fromS) + "&to=" + Math.round(toS));
    return refresh();
  }

  function resetZoom() {
    ui.window = null;
    replaceChartUrl(ui.range === "all" ? "" : "range=" + encodeURIComponent(ui.range));
    return refresh();
  }

  function onSort(idx) {
    ui.sortAsc = ui.sortIndex === idx ? !ui.sortAsc : true;
    ui.sortIndex = idx;
    savePref("dashboardSort", `${idx}:${ui.sortAsc ? "asc" : "desc"}`);
    rerender(); // client-side sort only, no fetch
  }

  function setView(mode) {
    ui.view = mode;
    storage.setItem("dashboardView", mode);
    // Visiting Advanced retires the calculators hint (#425) — its discoverability job is done.
    if (mode === "advanced" && !ui.hintDismissed) {
      ui.hintDismissed = true;
      storage.setItem("dashboardCalcHint", "dismissed");
    }
    rerender();
  }

  // Dismiss the Simple-view calculators hint (#425) without leaving Simple view.
  function dismissHint() {
    ui.hintDismissed = true;
    storage.setItem("dashboardCalcHint", "dismissed");
    rerender();
  }

  function setTheme(theme) {
    ui.theme = theme;
    storage.setItem("dashboardTheme", theme);
    applyTheme(theme); // updates <html data-theme>; the chart recolours on the next render
    rerender();
  }

  function toggleSeries(key) {
    ui.series = { ...ui.series, [key]: !ui.series[key] };
    storage.setItem("dashboardSeries", JSON.stringify(ui.series));
    rerender(); // visibility-only; the chart hides/shows the dataset, no refetch needed
  }

  // Pick the chart's hashrate-averaging window (#168). Persist it and refetch — the server returns
  // a different per-window series, so (unlike series visibility) this needs a round-trip.
  function setAvgWindow(w) {
    ui.avg = normalizeAvgWindow(w);
    storage.setItem("dashboardAvgWindow", ui.avg);
    return refresh();
  }

  applyTheme(ui.theme); // re-assert the (normalized) theme before the first paint
  if (sovereign) {
    listen("popstate", () => {
      const query = new URL(currentHref()).searchParams;
      const range = normalizeRange(query.get("range"));
      const window = windowFromUrl(query);
      if (range === ui.range && JSON.stringify(window) === JSON.stringify(ui.window)) return;
      ui.range = range;
      ui.window = window;
      return refresh();
    });
  }
  rerender(); // paint the loading shell immediately
  const firstLoad = tick(); // first data load
  schedule(tick, REFRESH_MS); // then live updates
  return { tick, firstLoad };
}

// Boot for real in the browser. Under `node --test` there is no `document`, so importing this
// module has no side effects and tests call initDashboard() themselves.
if (typeof document !== "undefined") initDashboard();
