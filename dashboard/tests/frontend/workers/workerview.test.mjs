import assert from "node:assert/strict";
import { test } from "node:test";
import { WorkerInspect } from "../../../mining_dashboard/web/static/workers/workerview.mjs";
import { renderToString } from "../helpers/render.mjs";
import { DETAIL, SENTINEL, readyInstance, stubSetState } from "./workerview-helpers.mjs";

// --- Table mode ------------------------------------------------------------------------------

test("table mode renders one row per writable key", () => {
  const out = renderToString(readyInstance().render());
  assert.match(out, /config-field-name">DONATION/);
  assert.match(out, /config-field-name">max_temp_c/);
  assert.match(out, /config-field-name">token/);
});

test("table mode: editing a row and applying builds the changes object (only the diff)", async () => {
  const inst = readyInstance();
  inst.state.tableEdits = { DONATION: "6" };
  let posted = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    posted = { url, body: JSON.parse(opts.body) };
    return { json: async () => ({ status: "applied" }) };
  };
  try {
    await inst.apply();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(posted.url, "/api/control/worker-apply");
  assert.deepEqual(posted.body, { worker: "rig1", changes: { DONATION: 6 } });
});

// --- JSON mode ---------------------------------------------------------------------------------

test("JSON mode: a parse error surfaces inline, not just on Apply", () => {
  const inst = readyInstance();
  inst.state.mode = "json";
  inst.onJsonInput("{not json");
  assert.match(inst.state.jsonError, /Not valid JSON/);
  assert.match(renderToString(inst.render()), /Not valid JSON/);
});

test("JSON mode: valid JSON builds the same shape of changes object as table mode", async () => {
  const inst = readyInstance();
  inst.state.mode = "json";
  inst.onJsonInput(JSON.stringify({ DONATION: 6 }));
  assert.equal(inst.state.jsonError, null);
  let posted = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    posted = JSON.parse(opts.body);
    return { json: async () => ({ status: "applied" }) };
  };
  try {
    await inst.apply();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.deepEqual(posted.changes, { DONATION: 6 }); // same shape the table-mode test posted
});

// --- Masked-token sentinel round-trip (#508/#440) -------------------------------------------

test("table mode: a masked value renders as a secret field, never raw sentinel JSON", () => {
  const out = renderToString(readyInstance().render());
  assert.doesNotMatch(out, /__secret__/); // never printed as raw JSON the operator could mangle
  assert.match(out, /type="password"/);
});

test("table mode: leaving the secret row blank keeps the token untouched", async () => {
  const inst = readyInstance();
  inst.state.tableEdits = { DONATION: "6" }; // token row untouched
  let posted = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    posted = JSON.parse(opts.body);
    return { json: async () => ({ status: "applied" }) };
  };
  try {
    await inst.apply();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.ok(!("token" in posted.changes)); // untouched — never resent, masked or otherwise
});

test("JSON mode: an untouched sentinel round-trips verbatim through the textarea", () => {
  const inst = readyInstance();
  inst.state.mode = "json";
  // editText is prefilled from last_applied at load() time — unmodified, it still carries the literal sentinel shape (the same "unless replaced" contract the Configuration view uses).
  assert.match(inst.state.editText, /__secret__/);
  const parsed = JSON.parse(inst.state.editText);
  assert.deepEqual(parsed.token, SENTINEL);
});

// --- File-fill button (#518, ~5 lines) ---------------------------------------------------------

test("the fill button reads a picked file into the JSON textarea via FileReader", async () => {
  const inst = readyInstance();
  inst.state.mode = "json";
  const content = JSON.stringify({ DONATION: 9 });
  let capturedOnLoad;
  class FakeFileReader {
    set onload(fn) {
      capturedOnLoad = fn;
    }
    readAsText() {
      this.result = content;
      capturedOnLoad();
    }
  }
  const realFileReader = globalThis.FileReader;
  globalThis.FileReader = FakeFileReader;
  try {
    inst.onFilePick({ target: { files: [{ name: "profile.json" }] } });
  } finally {
    globalThis.FileReader = realFileReader;
  }
  assert.equal(inst.state.editText, content);
  assert.equal(inst.state.jsonError, null);
});

test("the fill button is a no-op when the file picker is dismissed with no file", () => {
  const inst = readyInstance();
  const before = inst.state.editText;
  inst.onFilePick({ target: { files: [] } });
  assert.equal(inst.state.editText, before);
});

// --- Change history (#1014) -------------------------------------------------------------------

test("a config-apply history row lists its changed keys", () => {
  const detail = {
    ...DETAIL,
    history: [
      {
        applied_at: "2026-07-16 12:00",
        status: "applied",
        type: "apply",
        changes: { DONATION: 3 },
        reason: null,
      },
    ],
  };
  const out = renderToString(readyInstance(detail).render());
  assert.match(out, /DONATION/);
  assert.doesNotMatch(out, /upgrade →/);
});

test("a rig-upgrade history row shows the version it moved to, not the literal key 'version'", () => {
  const detail = {
    ...DETAIL,
    history: [
      {
        applied_at: "2026-07-16 12:00",
        status: "applied",
        type: "upgrade",
        changes: { version: "v1.12.0" },
        reason: null,
      },
    ],
  };
  const out = renderToString(readyInstance(detail).render());
  assert.match(out, /upgrade → v1\.12\.0/);
  assert.doesNotMatch(out, />version</); // never the raw changed-key name for an upgrade row
});

// --- Hashrate by config (#492) ----------------------------------------------------------------

test("renders one row per config version with its aggregated hashrate", () => {
  const detail = {
    ...DETAIL,
    hashrate_by_config: [
      {
        change_id: "cid2",
        applied_at: "2026-07-16 12:00",
        avg_h15: "4.00 kH/s",
        min_h15: "4.00 kH/s",
        max_h15: "4.00 kH/s",
        sample_count: 0,
        reason: null,
      },
      {
        change_id: "cid1",
        applied_at: "2026-07-16 10:00",
        avg_h15: "1.50 kH/s",
        min_h15: "1.00 kH/s",
        max_h15: "2.00 kH/s",
        sample_count: 2,
        reason: null,
      },
    ],
  };
  const out = renderToString(readyInstance(detail).render());
  assert.match(out, /cid2/);
  assert.match(out, /cid1/);
  assert.match(out, /1\.50 kH\/s/);
});

test("a version with no samples yet shows a dash, not a crash", () => {
  const detail = {
    ...DETAIL,
    hashrate_by_config: [
      {
        change_id: "cid1",
        applied_at: "2026-07-16 10:00",
        avg_h15: null,
        min_h15: null,
        max_h15: null,
        sample_count: 0,
        reason: null,
      },
    ],
  };
  const out = renderToString(readyInstance(detail).render());
  assert.match(out, /cid1/);
  assert.match(out, />—</);
});

test("no applied config versions yet falls back to an explanatory message", () => {
  const out = renderToString(readyInstance({ ...DETAIL, hashrate_by_config: [] }).render());
  assert.match(out, /No applied config changes to correlate hashrate against yet/);
});

// --- Hashrate chart (#1013/#1015) -------------------------------------------------------------

test("a rig with no hashrate history yet renders an honest empty state, not a broken chart", () => {
  const out = renderToString(readyInstance(DETAIL).render());
  assert.match(out, /No hashrate history for this rig yet/);
  // The range control still renders (the operator can still try a wider range).
  assert.match(out, /24 Hr/);
  assert.match(out, />All</);
});

test("a rig with samples renders the range control and the chart canvas, not the empty state", () => {
  const detail = {
    ...DETAIL,
    hashrate_history: { hashrate: [{ x: 1000, y: 500 }], markers: [] },
  };
  const out = renderToString(readyInstance(detail).render());
  assert.doesNotMatch(out, /No hashrate history for this rig yet/);
  assert.match(out, /<canvas/);
  assert.match(out, /24 Hr/);
  assert.match(out, /1 Wk/);
});

test("only the current chart range button is marked active", () => {
  const detail = { ...DETAIL, hashrate_history: { hashrate: [{ x: 1, y: 1 }], markers: [] } };
  const inst = readyInstance(detail);
  inst.state.chartRange = "1w";
  const out = renderToString(inst.render());
  assert.match(out, /class="btn-range active"[^>]*>1 Wk/);
});

test("clicking a range button refetches only the chart data, leaving an in-progress edit alone", async () => {
  const detail = { ...DETAIL, hashrate_history: { hashrate: [{ x: 1, y: 1 }], markers: [] } };
  const inst = readyInstance(detail);
  inst.state.tableEdits = { DONATION: "9" }; // an in-progress, unsaved edit
  let requested = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    requested = url;
    return {
      ok: true,
      json: async () => ({ hashrate_history: { hashrate: [{ x: 2, y: 2 }], markers: [] } }),
    };
  };
  try {
    await inst.setChartRange("1w");
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.match(requested, /\/api\/worker\?name=rig1&range=1w/);
  assert.equal(inst.state.chartRange, "1w");
  assert.equal(inst.state.chartLoading, false);
  assert.deepEqual(inst.state.detail.hashrate_history.hashrate, [{ x: 2, y: 2 }]);
  // Nothing else in detail, and no unrelated state, was touched by the chart-only refresh.
  assert.deepEqual(inst.state.tableEdits, { DONATION: "9" });
  assert.equal(inst.state.phase, "ready");
});

test("load() requests the current chart range from /api/worker", async () => {
  const inst = new WorkerInspect({ name: "rig1", onClose: () => {} });
  stubSetState(inst);
  let requested = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    requested = url;
    return { ok: true, json: async () => DETAIL };
  };
  try {
    await inst.load();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.match(requested, /range=24h/); // the default chart-range preference
  assert.equal(inst.state.phase, "ready");
});

test("a detail payload missing hashrate_history entirely still renders (defensive, no crash)", () => {
  const withoutChart = { ...DETAIL };
  delete withoutChart.hashrate_history;
  const out = renderToString(readyInstance(withoutChart).render());
  assert.match(out, /No hashrate history for this rig yet/);
});
