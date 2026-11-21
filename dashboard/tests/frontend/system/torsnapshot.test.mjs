import assert from "node:assert/strict";
import { test } from "node:test";

import { SettingsPage } from "../../../mining_dashboard/web/static/sovereign/settings.mjs";
import {
  TorDiagnostics,
  torSnapshotRows,
} from "../../../mining_dashboard/web/static/sovereign/tor-diagnostics.mjs";
import { DiagnosticsPanel } from "../../../mining_dashboard/web/static/system/diagview.mjs";
import { renderToString } from "../helpers/render.mjs";

const SNAP = {
  taken_at: 1795167550,
  control: "ok",
  version: "0.4.9.17",
  bootstrap: { progress: 100, tag: "done", changed_at: 1795089662 },
  circuits: [
    { state: "BUILT", purpose: "GENERAL", count: 2 },
    { state: "LAUNCHED", purpose: "HS_SERVICE_HSDIR", count: 12 },
  ],
  guards: { down: 1, up: 2 },
  consensus: { source: "file", valid_after: 1795089600, valid_until: 1795100400, age_sec: 3600 },
};

function panel(state) {
  const component = new TorDiagnostics({});
  component.state = { ...component.state, ...state };
  component.setState = (update) => Object.assign(component.state, update);
  return component;
}

test("every snapshot field from the first acceptance criterion is a row", () => {
  assert.deepEqual(torSnapshotRows(SNAP), [
    ["Control port", "ok"],
    ["Version", "0.4.9.17"],
    ["Bootstrap", "100% (done), last change 2026-11-19T12:01:02Z"],
    [
      "Consensus",
      "valid after 2026-11-19T12:00:00Z, valid until 2026-11-19T15:00:00Z, age 60 min (source: file)",
    ],
    ["Guards", "down 1, up 2"],
    ["Circuits", "BUILT GENERAL 2, LAUNCHED HS_SERVICE_HSDIR 12"],
  ]);
});

test("the check runs diag-doctor and renders the snapshot the host returned", async () => {
  const realFetch = globalThis.fetch;
  const realTimeout = globalThis.setTimeout;
  const ID = "22222222-2222-4222-8222-222222222222";
  const paths = [];
  globalThis.fetch = async (path) => {
    paths.push(path);
    const body = path.includes("diag-doctor")
      ? { id: ID }
      : { status: "applied", doctor: { checks: [] }, tor: SNAP };
    return { status: 200, ok: true, json: async () => body };
  };
  globalThis.setTimeout = (cb) => {
    cb();
    return 0;
  };
  try {
    const component = panel({});
    await component.check();
    assert.equal(component.state.phase, "done");
    assert.ok(paths.some((p) => p.includes("diag-doctor")));
    const out = renderToString(component.render());
    assert.match(out, /LAUNCHED HS_SERVICE_HSDIR 12/);
    assert.match(out, /valid until 2026-11-19T15:00:00Z/);
  } finally {
    globalThis.fetch = realFetch;
    globalThis.setTimeout = realTimeout;
  }
});

test("an unreachable control port renders as unreachable, not as an empty panel", () => {
  const snap = {
    control: "unreachable",
    bootstrap: { progress: null, tag: null, changed_at: null },
    circuits: [],
    guards: {},
    consensus: { source: "none", valid_after: null, valid_until: null, age_sec: null },
  };
  const rows = Object.fromEntries(torSnapshotRows(snap));
  assert.equal(rows["Control port"], "unreachable");
  assert.equal(rows.Bootstrap, "unknown, last change unknown");
  assert.equal(rows.Circuits, "none reported");
  assert.match(renderToString(panel({ phase: "done", snap }).render()), /lan-fail">\s*unreachable/);
});

test("a report without a snapshot says so", () => {
  assert.deepEqual(torSnapshotRows(undefined), []);
  assert.deepEqual(torSnapshotRows([]), []);
  assert.match(renderToString(panel({ phase: "done", snap: null }).render()), /no Tor snapshot/);
});

test("the Settings page offers the Tor check only on a controllable session", () => {
  const on = renderToString(
    new SettingsPage({ state: { control_enabled: true }, connected: true }).render(),
  );
  assert.match(on, /Tor diagnostics/);
  assert.match(on, /Check Tor now/);
  const off = renderToString(new SettingsPage({ state: { control_enabled: false } }).render());
  assert.match(off, /Tor diagnostics/);
  assert.doesNotMatch(off, /Check Tor now/);
});

test("the Service diagnostics card shows the Tor snapshot beside the health report (#4262)", () => {
  const card = (result) => {
    const c = new DiagnosticsPanel({ enabled: true });
    c.props = { enabled: true };
    c.state = { ...c.state, healthPhase: "done", healthResult: { doctor: { checks: [] }, ...result } };
    return renderToString(c.render());
  };
  const out = card({ tor: SNAP });
  assert.match(out, /card-subhead">Tor</);
  assert.match(out, /LAUNCHED HS_SERVICE_HSDIR 12/);
  assert.match(out, /valid until 2026-11-19T15:00:00Z/);
  assert.match(out, /0\.4\.9\.17/);
  assert.doesNotMatch(card({}), /card-subhead">Tor</);
  assert.match(card({ tor: { control: "unreachable" } }), /status-bad">unreachable/);
});
