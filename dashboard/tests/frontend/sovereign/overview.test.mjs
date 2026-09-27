import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { SovereignOverview } from "../../../mining_dashboard/web/static/sovereign/overview.mjs";
import { render } from "../helpers/render.mjs";

const BASE = JSON.parse(
  readFileSync(new URL("../fixtures/state.json", import.meta.url), "utf8"),
);
const noop = () => {};
const UI = { range: "all", window: null, series: {}, avg: "10m" };

function overview(patch = {}, onInspect = noop) {
  return render(SovereignOverview, {
    state: Object.assign(structuredClone(BASE), patch),
    ui: UI,
    onView: noop,
    onRange: noop,
    onZoom: noop,
    onResetZoom: noop,
    onToggleSeries: noop,
    onAvgWindow: noop,
    onInspect,
  });
}

test("overview reports every worker attention signal once", () => {
  for (const worker of [
    { status: "offline" },
    { status: "online", api_ok: false },
    { status: "online", reject_flag: { text: "!" } },
    { status: "online", rigforge: { miner_down: true } },
  ]) {
    assert.match(overview({ workers: [worker] }), /1 worker feed needs attention/);
  }

  assert.match(
    overview({
      workers: [
        { status: "offline", api_ok: false, reject_flag: {}, rigforge: { miner_down: true } },
      ],
    }),
    /1 worker feed needs attention/,
  );
});

test("overview distinguishes partial, missing, and invalid mining records", () => {
  assert.match(
    overview({
      earnings_summary: { xmr: { enabled: true, actual_30d: 0.125, partial: true } },
      shares_window: { count: 19, ok: true },
    }),
    /Recorded XMR · 30 days \*.*0\.125000 XMR.*Partial payout history.*Shares in window.*19/s,
  );

  const missing = overview({
    earnings_summary: { xmr: { enabled: true, actual_30d: null, partial: false } },
    proxy_workers: null,
    shares_window: { count: null, ok: true },
  });
  assert.match(missing, /Payout tracking unavailable/);
  assert.match(missing, /— connected workers/);
  assert.match(missing, /Shares in window<\/span><strong>—/);

  const invalid = overview({ shares_window: { count: 19, ok: false } });
  assert.match(invalid, /Shares in window<\/span><strong>—/);
  assert.match(invalid, /Share window unavailable/);
  assert.doesNotMatch(invalid, /Shares in window<\/span><strong>19/);
});

test("overview bounds the worker preview to five rows", () => {
  const workers = Array.from({ length: 7 }, (_, index) => ({
    name: `rig-${index + 1}`,
    status: "online",
    h60_str: `${index + 1} H/s`,
  }));
  const html = overview({ workers });

  assert.match(html, /All 7 workers/);
  for (const worker of workers.slice(0, 5)) assert.match(html, new RegExp(worker.name));
  assert.doesNotMatch(html, /rig-6|rig-7/);
});

test("disabled Tari and XvB facts stay out of the overview", () => {
  const html = overview({
    tari: { active: false, connected: false, status: "Waiting..." },
    xvb_calc: { enabled: false },
  });

  assert.doesNotMatch(html, /Tari merge mining|XvB routed|Eligibility/);
  assert.doesNotMatch(html, /Tari: Waiting/);
});

test("worker inspection requires both server control and a handler", () => {
  for (const [control_enabled, handler, interactive] of [
    [false, noop, false],
    [false, null, false],
    [true, null, false],
    [true, noop, true],
  ]) {
    const html = overview({ control_enabled, workers: [BASE.workers[0]] }, handler);
    assert.equal(/<button type="button" class="sov-worker"/.test(html), interactive);
  }
});

test("missing health telemetry is attention, not a healthy claim", () => {
  const html = overview({
    workers: [],
    sync: {},
    topology: {},
    system: {},
    shares_window: { count: 0, ok: true },
  });

  for (const message of [
    "Monero sync unavailable",
    "Configured egress unavailable",
    "CPU unavailable",
    "Memory unavailable",
    "Disk unavailable",
  ]) {
    assert.match(html, new RegExp(message));
  }
  assert.doesNotMatch(html, /No attention items/);
});
