import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { SovereignApp } from "../../../mining_dashboard/web/static/sovereign/app.mjs";
import { render } from "../helpers/render.mjs";

const BASE = JSON.parse(
  readFileSync(new URL("../fixtures/state.json", import.meta.url), "utf8"),
);
const UI = {
  view: "simple",
  range: "all",
  window: null,
  series: {},
  avg: "10m",
  theme: "auto",
  sortIndex: null,
  sortAsc: true,
  inspectWorker: null,
};
const noop = () => {};
const PROPS = {
  connected: true,
  ui: UI,
  onRange: noop,
  onSort: noop,
  onTheme: noop,
  onZoom: noop,
  onResetZoom: noop,
  onToggleSeries: noop,
  onAvgWindow: noop,
  onInspect: noop,
  onCloseInspect: noop,
  onRetry: noop,
};

function renderPage(page, patch = {}) {
  const prior = globalThis.location;
  globalThis.location = { hash: `#${page}` };
  try {
    return render(SovereignApp, { state: structuredClone(BASE), ...PROPS, ...patch });
  } finally {
    if (prior === undefined) delete globalThis.location;
    else globalThis.location = prior;
  }
}

test("SovereignApp renders every route from the shared state contract", () => {
  const expected = {
    overview: "Own the whole",
    machines: "Every worker, part of your operation",
    earnings: "What you have earned",
    network: "Routes describe configuration",
    activity: "Recent mining activity",
    settings: "Configuration editor",
    maintenance: "Service diagnostics",
    help: "About this preview",
  };
  for (const [page, text] of Object.entries(expected)) {
    assert.match(renderPage(page), new RegExp(text), `${page} did not render its content`);
  }
});

test("SovereignApp shows missing-state and disconnected states", () => {
  assert.match(renderPage("overview", { state: null }), /Connecting to your operation/);
  assert.match(
    renderPage("overview", { connected: false }),
    /Disconnected — showing the last snapshot from 00:00:00/,
  );
  assert.match(
    renderPage("overview", { state: null, connected: false }),
    /Disconnected — no snapshot available/,
  );
});

test("worker controls stay gated by control_enabled", () => {
  const ui = { ...UI, inspectWorker: BASE.workers[0].name };
  assert.doesNotMatch(renderPage("overview", { ui }), /worker-inspect/);

  const state = structuredClone(BASE);
  state.control_enabled = true;
  assert.match(renderPage("overview", { state, ui }), /worker-inspect/);
});

test("an empty fleet shows the stack's real worker connection endpoint", () => {
  const state = { ...structuredClone(BASE), workers: [], host_ip: "192.0.2.10", stratum_port: 4444 };
  assert.match(renderPage("machines", { state }), /192\.0\.2\.10:4444/);
  state.host_ip = "Unknown Host";
  state.host_addr = "pithead.test";
  assert.match(renderPage("machines", { state }), /pithead\.test:4444/);
});
