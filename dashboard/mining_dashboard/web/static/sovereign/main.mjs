import { html, render } from "../app/preact.mjs";
import { EarningsPage } from "./earnings.mjs";
import { createNavigation, PAGES, readRoute, routeUrl } from "./navigation.mjs";
import { createPolling } from "./polling.mjs";
import { Shell } from "./shell.mjs";
import { createSyncHistory } from "./sync-model.mjs";
import { overviewContent } from "./sync-view.mjs";

export function initSovereign({
  win = window,
  doc = document,
  storage = localStorage,
  fetchFn = fetch,
  hasUnsavedChanges = () => false,
  renderPage,
  renderSection,
} = {}) {
  const root = doc.getElementById("app");
  root.replaceChildren();
  const read = (key) => {
    try {
      return storage.getItem(key);
    } catch {
      return null;
    }
  };
  const save = (key, value) => {
    try {
      storage.setItem(key, value);
    } catch {}
  };
  let theme = ["light", "dark"].includes(read("dashboardTheme")) ? read("dashboardTheme") : "auto";
  const initial = new URL(win.location.href);
  if (
    !["page", "view", "advanced"].some((key) => initial.searchParams.has(key)) &&
    read("pitheadPage")
  )
    initial.searchParams.set("page", read("pitheadPage"));
  let route = readRoute(initial, read("dashboardView"));
  win.history.replaceState(null, "", routeUrl(initial, route.page, route.advanced));
  let snapshotStorage;
  try {
    snapshotStorage = win.sessionStorage;
  } catch {}
  const syncHistory = createSyncHistory(snapshotStorage);
  let data = {
    snapshot: syncHistory.snapshot,
    connected: !syncHistory.snapshot,
    sessionExpired: false,
  };
  const dirtyEarnings = new Set();
  const pageRenderer = (page, state) =>
    renderPage?.(page, state) ||
    (page === "earnings"
      ? html`<${EarningsPage} state=${state} connected=${data.connected} sessionExpired=${data.sessionExpired}
        url=${win.location.href} onDirtyChange=${(key, dirty) => {
          if (dirty) dirtyEarnings.add(key);
          else dirtyEarnings.delete(key);
        }} />`
      : null);
  const paint = () => {
    doc.title = `Pithead — ${PAGES[route.page][0]}`;
    render(
      html`<${Shell} route=${route} url=${win.location.href} state=${data.snapshot}
      connected=${data.connected} sessionExpired=${data.sessionExpired}
      theme=${theme} onTheme=${(value) => {
        theme = ["light", "dark"].includes(value) ? value : "auto";
        save("dashboardTheme", theme);
        doc.documentElement.dataset.theme = theme;
        paint();
      }} onNavigate=${(page, section) => navigation.go(page, section)}
      onRetry=${() => polling.tick()} renderPage=${(page, state) => overviewContent({ page, state, history: syncHistory, connected: data.connected, renderPage: pageRenderer })} renderSection=${renderSection} />`,
      root,
    );
  };
  const navigation = createNavigation({
    win,
    preference: read("dashboardView"),
    dirty: () => hasUnsavedChanges() || dirtyEarnings.size > 0,
    onChange: (next) => {
      const pageChanged = route.page !== next.page;
      route = next;
      save("pitheadPage", route.page);
      paint();
      if (pageChanged) doc.getElementById("page-title")?.focus();
    },
  });
  const polling = createPolling({
    initialSnapshot: syncHistory.snapshot,
    fetchFn: (signal) => {
      const params = new URL(win.location.href).searchParams;
      const query = new URLSearchParams();
      for (const key of ["range", "from", "to", "avg"])
        if (params.has(key)) query.set(key, params.get(key));
      return fetchFn(`/api/state?${query}`, { signal, cache: "no-store" });
    },
    publish: (next) => {
      if (next.connected) syncHistory.observe(next.snapshot);
      data = next;
      paint();
    },
  });
  doc.documentElement.dataset.theme = theme;
  const click = (event) => {
    if (
      event.defaultPrevented ||
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    )
      return;
    const anchor = event.target.closest?.("a[href]");
    if (!anchor) return;
    const url = new URL(anchor.href, win.location.href);
    if (
      url.origin !== win.location.origin ||
      url.pathname !== win.location.pathname ||
      !url.searchParams.has("page")
    )
      return;
    event.preventDefault();
    const target = readRoute(url);
    navigation.go(target.page, target.advanced);
  };
  root.addEventListener("click", click);
  paint();
  void polling.tick();
  return {
    navigation,
    polling,
    close() {
      navigation.close();
      polling.close();
      root.removeEventListener("click", click);
      render(null, root);
    },
  };
}

if (typeof document !== "undefined" && document.getElementById("app")) initSovereign();
