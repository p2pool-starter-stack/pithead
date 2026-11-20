import assert from "node:assert/strict";
import { test } from "node:test";

import { DiagnosticsPanel } from "../../../mining_dashboard/web/static/system/diagview.mjs";
import { torSnapshotRows } from "../../../mining_dashboard/web/static/system/torsnapshot.mjs";
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

function render(tor) {
  const panel = new DiagnosticsPanel({ enabled: true });
  panel.props = { enabled: true };
  panel.state = {
    ...panel.state,
    healthPhase: "done",
    healthResult: { status: "applied", doctor: { checks: [] }, tor },
  };
  return renderToString(panel.render());
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

test("Service diagnostics renders the Tor snapshot beside the health report", () => {
  const out = render(SNAP);
  assert.match(out, /<h3 class="card-subhead">Tor<\/h3>/);
  assert.match(out, /LAUNCHED HS_SERVICE_HSDIR 12/);
  assert.match(out, /valid until 2026-11-19T15:00:00Z/);
});

test("an unreachable control port renders as unreachable, not as an empty panel", () => {
  const snap = {
    control: "unreachable",
    version: null,
    bootstrap: { progress: null, tag: null, changed_at: null },
    circuits: [],
    guards: {},
    consensus: { source: "none", valid_after: null, valid_until: null, age_sec: null },
  };
  const rows = Object.fromEntries(torSnapshotRows(snap));
  assert.equal(rows["Control port"], "unreachable");
  assert.equal(rows.Bootstrap, "unknown, last change unknown");
  assert.equal(rows.Circuits, "none reported");
  const out = render(snap);
  assert.match(out, /status-bad">Control port/);
});

test("a report without a snapshot renders no Tor section", () => {
  assert.deepEqual(torSnapshotRows(undefined), []);
  assert.deepEqual(torSnapshotRows([]), []);
  assert.doesNotMatch(render(undefined), /card-subhead">Tor</);
});
