// Open /checks on sovereign-preview.mjs. Real Preact + native DOM, no test dependencies.
// The fixture server refuses every write; this suite never asks for one.
import { html, render } from "/static/app/preact.mjs";
import { SovereignApp } from "/static/sovereign/app.mjs";

const root = document.getElementById("app");
const output = document.getElementById("results");
const originalFetch = globalThis.fetch;
const state = await (await originalFetch("/api/state")).json();
const ui = { view: "simple", range: "all", window: null, series: {}, avg: "10m", theme: "dark", sortIndex: null, sortAsc: true };
const noop = () => {};
const handlers = { onTheme: noop, onRetry: noop, onRange: noop, onZoom: noop, onResetZoom: noop, onToggleSeries: noop, onAvgWindow: noop, onSort: noop, onInspect: noop, onCloseInspect: noop };
let failures = 0;
const lines = [];
const assert = (condition, message) => { if (!condition) throw new Error(message); };
async function until(check, message) {
  const deadline = performance.now() + 3000;
  while (!check()) {
    if (performance.now() > deadline) throw new Error(message);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
async function check(name, run) {
  try { await run(); lines.push(`PASS ${name}`); }
  catch (error) { failures++; lines.push(`FAIL ${name}: ${error.message}`); }
  output.textContent = lines.join("\n");
}
const paint = (props = {}) => render(html`<${SovereignApp} state=${state} connected=${true} ui=${ui} ...${handlers} ...${props} />`, root);
async function navigate(page) {
  location.hash = page;
  await until(() => root.querySelector(`a[aria-current="page"][href="#${page}"]`), `Route ${page} did not render`);
}
const button = (text) => [...root.querySelectorAll("button")].find((b) => b.textContent.includes(text));
const unloadEvent = () => new Event("beforeunload", { cancelable: true });

try {
  globalThis.fetch = async (url, options) => {
    assert(!options?.method || options.method === "GET", "Browser suite attempted a write");
    if (url === "/api/config") return new Response(JSON.stringify({ dashboard: { timezone: "UTC" }, _editable_keys: ["dashboard.timezone"] }));
    return originalFetch(url, options);
  };
  location.hash = "overview";
  paint();
  await check("one content landmark and heading; mobile layout does not overflow", async () => {
    await until(() => root.querySelector("h1"), "App did not mount");
    assert(document.documentElement.dataset.ui === "sovereign", "Preview theme did not initialize");
    assert(globalThis.Chart?.getChart(root.querySelector("canvas")), "Production chart did not mount");
    assert(root.querySelectorAll("main").length === 1, "Expected one main");
    assert(root.querySelectorAll("h1").length === 1, "Expected one h1");
    assert(document.documentElement.scrollWidth <= innerWidth, "Page overflows horizontally");
  });
  await check("hash navigation focuses the route heading and announces it", async () => {
    await navigate("machines");
    const heading = root.querySelector("h1");
    assert(document.activeElement === heading, "Route heading did not receive focus");
    assert(root.querySelector('[aria-live="polite"]').textContent === "Your machines", "Missing route announcement");
  });
  await check("worker addresses stay hidden until explicitly revealed", async () => {
    const table = root.querySelector("#workers-table");
    assert(!table.textContent.includes("192.0.2.21"), "Address exposed by default");
    button("Reveal worker addresses").click();
    await until(() => table.textContent.includes("192.0.2.21"), "Reveal did not show addresses");
    button("Hide worker addresses").click();
    await until(() => !table.textContent.includes("192.0.2.21"), "Hide did not mask addresses");
  });
  await check("search and attention filters combine without changing the fleet count", async () => {
    const search = root.querySelector('input[type="search"]');
    search.value = "garage";
    search.dispatchEvent(new Event("input", { bubbles: true }));
    button("Needs attention").click();
    await until(() => root.querySelectorAll("#workers-tbody tr").length === 1, "Filter did not narrow workers");
    assert(root.querySelector("#workers-tbody").textContent.includes("garage-spare"), "Wrong worker survived");
    assert(root.querySelector(".sov-nav-count").textContent === "3", "Filtered count replaced fleet count");
  });
  await check("dirty settings survive actual unmounts of neighboring routes and polling", async () => {
    await navigate("settings");
    await until(() => root.querySelector("textarea"), "Editor did not load");
    const editor = root.querySelector("textarea");
    editor.closest("details").open = true;
    editor.value = '{"dashboard":{"timezone":"Europe/London"}}';
    editor.dispatchEvent(new Event("input", { bubbles: true }));
    await until(() => button("Discard edits"), "Draft was not marked dirty");
    const dirty = unloadEvent();
    dispatchEvent(dirty);
    assert(dirty.defaultPrevented, "Dirty draft did not protect navigation away");
    await navigate("overview");
    paint({ state: structuredClone(state) });
    await navigate("settings");
    assert(root.querySelector("textarea") === editor, "Editor was remounted and draft could be lost");
    assert(editor.value.includes("Europe/London"), "Draft was overwritten");
    button("Discard edits").click();
    await until(() => !button("Discard edits"), "Discard did not finish");
    const clean = unloadEvent();
    dispatchEvent(clean);
    assert(!clean.defaultPrevented, "Clean editor still warns");
  });
  await check("failed refresh labels the retained snapshot and offers retry", async () => {
    await navigate("overview");
    let retried = false;
    paint({ connected: false, onRetry: () => { retried = true; } });
    assert(root.textContent.includes("showing the last snapshot"), "Missing stale warning");
    assert(root.textContent.includes("24.80"), "Last snapshot disappeared");
    button("Retry now").click();
    assert(retried, "Retry button is disconnected");
  });
  await check("teardown removes the unsaved-change listener", async () => {
    await navigate("settings");
    const editor = root.querySelector("textarea");
    editor.value = '{"dashboard":{"timezone":"UTC+1"}}';
    editor.dispatchEvent(new Event("input", { bubbles: true }));
    await until(() => button("Discard edits"), "Draft did not become dirty");
    render(null, root);
    const event = unloadEvent();
    dispatchEvent(event);
    assert(!event.defaultPrevented, "Unmount left an unload listener attached");
  });
} finally {
  render(null, root);
  globalThis.fetch = originalFetch;
  output.dataset.failures = String(failures);
  output.dataset.complete = "true";
  output.textContent += `\n${lines.length - failures}/${lines.length} passed · viewport ${innerWidth}px`;
  document.title = failures ? "FAIL · Sovereign browser checks" : "PASS · Sovereign browser checks";
}
