import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { ChartCard } from "../../../mining_dashboard/web/static/app/chart.mjs";
import { PageContent, SettingsPage } from "../../../mining_dashboard/web/static/sovereign/pages.mjs";
import { render } from "../helpers/render.mjs";

const state = JSON.parse(readFileSync(new URL("../fixtures/state.json", import.meta.url)));

test("compact chart keeps averaging and series controls inside a native disclosure", () => {
  const props = { chart: state.chart, range: "24h", avgWindow: "10m", compact: true };
  const compact = render(ChartCard, props);
  assert.match(compact, /<details class="chart-options">/);
  assert.match(compact, /<summary>Chart options/);
  assert.match(compact, /aria-label="Hashrate averaging window"/);
  assert.match(compact, /aria-label="Toggle series"/);
  assert.doesNotMatch(render(ChartCard, { ...props, compact: false }), /<details/);
});

test("settings warns on reload for dirty drafts and pending commits, but not clean state", () => {
  const page = new SettingsPage({ state });
  let warned = false;
  const event = { preventDefault() { warned = true; } };
  page.editor.current = { state: { editText: "{}", pristine: "{}", phase: "form" } };
  page.beforeUnload(event);
  assert.equal(warned, false);
  page.editor.current.state.editText = '{"changed":true}';
  page.beforeUnload(event);
  assert.equal(warned, true);
  assert.equal(event.returnValue, "");
  warned = false;
  page.editor.current.state = { editText: "{}", pristine: "{}", phase: "committing" };
  page.beforeUnload(event);
  assert.equal(warned, true);
});

test("Sovereign network summaries do not reveal payout wallet addresses", () => {
  const sample = structuredClone(state);
  sample.stratum.wallet = "PRIVATE_XMR_WALLET";
  sample.tari.wallet = "PRIVATE_TARI_WALLET";
  sample.tari.active = true;
  const output = render(PageContent, { page: "network", state: sample });
  assert.doesNotMatch(output, /PRIVATE_.*_WALLET/);
});
