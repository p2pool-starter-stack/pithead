import assert from "node:assert/strict";
import { test } from "node:test";
import { StatsTable } from "../../../mining_dashboard/web/static/workers/workerview.mjs";
import { contrastRatio, DARK_BLOCK, DASHBOARD_CSS, LIGHT_BLOCK, themeToken } from "../helpers/contrast.mjs";
import { renderToString } from "../helpers/render.mjs";
import { DETAIL, SENTINEL, readyInstance, stubSetState } from "./workerview-helpers.mjs";

// --- One-click rig upgrade (#597) -------------------------------------------------------------

const UPG_DETAIL = {
  ...DETAIL,
  rigforge: { version: "1.11.1", stats: [] },
  rigforge_update: { available: true, latest: "v1.11.2", url: "https://h/v1.11.2" },
};

test("upgrade button gates on rigforge_update + an editable, control-enabled worker (#597)", () => {
  assert.match(renderToString(readyInstance(UPG_DETAIL).render()), /Upgrade rig…/);
  // Notify-only without an operator-set host or with control off — badge yes, button no.
  const noEdit = renderToString(readyInstance({ ...UPG_DETAIL, editable: false }).render());
  assert.match(noEdit, /New RigForge release/);
  assert.doesNotMatch(noEdit, /Upgrade rig…/);
  const noCtl = renderToString(readyInstance({ ...UPG_DETAIL, control_enabled: false }).render());
  assert.doesNotMatch(noCtl, /Upgrade rig…/);
  // No update derived -> no badge, no button.
  const current = renderToString(readyInstance({ ...UPG_DETAIL, rigforge_update: null }).render());
  assert.doesNotMatch(current, /Upgrade rig…|New RigForge release/);
});

test("arming swaps the button for confirm/cancel; cancel disarms (#597)", () => {
  const inst = readyInstance(UPG_DETAIL);
  inst.state.upgArmed = true;
  const armed = renderToString(inst.render());
  assert.match(armed, /Confirm upgrade/);
  assert.match(armed, /Cancel/);
  assert.doesNotMatch(armed, /Upgrade rig…/);
});

test("upgrade() POSTs {worker, version} and renders the terminal result (#597)", async () => {
  const inst = readyInstance(UPG_DETAIL);
  let posted = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (posted === null && url === "/api/control/worker-upgrade") {
      posted = { url, body: JSON.parse(opts.body) };
      return { status: 200, json: async () => ({ status: "noop", note: "already on v1.11.2" }) };
    }
    return { ok: true, status: 200, json: async () => UPG_DETAIL }; // the load() refresh
  };
  try {
    await inst.upgrade();
    await new Promise((r) => setImmediate(r)); // flush the fire-and-forget load() refresh
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(posted.url, "/api/control/worker-upgrade");
  assert.deepEqual(posted.body, { worker: "rig1", version: "v1.11.2" });
  assert.equal(inst.state.upgBusy, false);
  assert.match(renderToString(inst.render()), /Already up to date/);
});

test("terminal statuses render their calm/red variants (#597)", () => {
  const inst = readyInstance(UPG_DETAIL);
  inst.state.upgResult = { status: "throttled", reason: "throttled: retry after the window" };
  assert.match(renderToString(inst.render()), /Throttled by the rig — retry later/);
  inst.state.upgResult = { status: "rolled_back", reason: "miner did not return live" };
  assert.match(renderToString(inst.render()), /Rolled back/);
});

// --- RigForge new-release callout (#596) ----------------------------------------------------

test("Inspect surfaces the RigForge new-release callout only when the server derived one (#596)", () => {
  const behind = {
    ...DETAIL,
    rigforge: { version: "1.11.1", stats: [] },
    rigforge_update: { available: true, latest: "v1.11.2", url: "https://h/v1.11.2" },
  };
  const out = renderToString(readyInstance(behind).render());
  assert.match(out, /New RigForge release v1\.11\.2 available/);
  assert.match(out, /href="https:\/\/h\/v1\.11\.2"/);

  // Current rig / plain xmrig: the server sends null -> no callout, no error.
  const current = { ...DETAIL, rigforge_update: null };
  assert.doesNotMatch(renderToString(readyInstance(current).render()), /New RigForge release/);
});

// --- StatsTable value contrast (#1232) ------------------------------------------------------
// A plain metric renders with variant "outline" — STAT_VALUE_CLS has no entry for it, so before the
// fix the value <td> got an empty class (no colour/weight, reading as disabled text in dark mode).
// The fix puts every value in `.stat-value`, with status-ok/warn/bad layered on top for a flagged
// metric; these two tests catch a regression to either the markup or the CSS rule itself.

test("StatsTable: a plain outline value still gets the stat-value class, not an empty one (#1232)", () => {
  const out = renderToString(StatsTable({ stats: [{ label: "Governor", value: "performance", variant: "outline" }] }));
  const valueCell = out.match(/<td class="([^"]*)">performance<\/td>/);
  assert.ok(valueCell, `expected a value <td> for the outline stat, got: ${out}`);
  assert.match(valueCell[1], /\bstat-value\b/);
  // The old code emitted `STAT_VALUE_CLS[s.variant] || ""`, which for "outline" (or any variant with no colour entry) rendered class="" — an empty class is exactly the regression.
  assert.notEqual(valueCell[1].trim(), "");
});

test("StatsTable: a warn-variant value keeps its status colour alongside stat-value (#1232)", () => {
  const out = renderToString(StatsTable({ stats: [{ label: "Temp / max", value: "78°C / 90°C", variant: "warn" }] }));
  const valueCell = out.match(/<td class="([^"]*)">78°C \/ 90°C<\/td>/);
  assert.ok(valueCell, `expected a value <td> for the warn stat, got: ${out}`);
  assert.match(valueCell[1], /\bstat-value\b/);
  assert.match(valueCell[1], /\bstatus-warn\b/);
});

test("dashboard.css: .stat-value declares an explicit --text colour, not an empty/inherited one (#1232)", () => {
  const rule = DASHBOARD_CSS.match(/\.stat-value\s*\{([^}]*)\}/);
  assert.ok(rule, "expected a .stat-value rule in dashboard.css");
  assert.match(rule[1], /color:\s*var\(--text\)/);
  assert.match(rule[1], /font-weight:\s*6\d\d/); // 600-ish, matching the top stat-card values
});

test("dashboard.css: .stat-value's --text on --card meets WCAG AA (>= 4.5:1) in dark AND light (#1232)", () => {
  // Dark is the base palette; light is the explicit override block — pull each theme's pair independently.
  const darkText = themeToken(DASHBOARD_CSS, DARK_BLOCK, "--text");
  const darkCard = themeToken(DASHBOARD_CSS, DARK_BLOCK, "--card");
  const lightText = themeToken(DASHBOARD_CSS, LIGHT_BLOCK, "--text");
  const lightCard = themeToken(DASHBOARD_CSS, LIGHT_BLOCK, "--card");

  const darkRatio = contrastRatio(darkText, darkCard);
  const lightRatio = contrastRatio(lightText, lightCard);
  assert.ok(darkRatio >= 4.5, `dark .stat-value contrast ${darkRatio.toFixed(2)}:1 is below AA (4.5:1)`);
  assert.ok(lightRatio >= 4.5, `light .stat-value contrast ${lightRatio.toFixed(2)}:1 is below AA (4.5:1)`);
});

// --- Prefill provenance (#1235) ----------------------------------------------------------------

test("table mode prefills from the rig's own config and labels every other case (#1235)", () => {
  // Label text is proven at the logic tier (fieldNote, workerlogic.test.mjs); this proves the render.
  const withRig = { ...DETAIL, rig_config: { DONATION: 9, max_temp_c: 85 } };
  const out = renderToString(readyInstance(withRig).render());
  assert.match(out, /value="9"/); // the rig's DONATION
  assert.match(out, /value="85"/); // the rig's max_temp_c
  assert.doesNotMatch(out, /value="5"/); // not the last-applied DONATION
  assert.doesNotMatch(out, /value="70"/); // nor its max_temp_c
  const noRig = { ...DETAIL, last_applied: { DONATION: 5 }, rig_config: null };
  const fell = renderToString(readyInstance(noRig).render());
  assert.match(fell, /last applied from here/);
  assert.equal((fell.match(/could not read from the rig/g) || []).length, 2); // max_temp_c, token
  assert.doesNotMatch(out, /the rig's live feed doesn't expose these values/); // stale claim, #1235
  assert.match(out, /Prefilled with what the rig is running now/);
});
