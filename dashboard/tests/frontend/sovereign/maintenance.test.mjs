import assert from "node:assert/strict";
import { test } from "node:test";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { Maintenance, ServerHealth } from "../../../mining_dashboard/web/static/sovereign/maintenance.mjs";
import { Inspect } from "../../../mining_dashboard/web/static/sovereign/inspect.mjs";
import { renderToString } from "../helpers/render.mjs";

test("read-only and non-mining server health distinguish missing telemetry from zero", () => {
  const out = renderToString(html`<${ServerHealth} state=${{ system: { cpu: { percent: "0%" } } }} />`);
  assert.match(out, /0%/);
  assert.match(out, /Not reported/);
  assert.match(out, /server without a local miner can still be healthy/);
  const maintenance = renderToString(html`<${Maintenance} state=${{ control_enabled: false }} />`);
  assert.match(maintenance, /signed-in session/);
  assert.doesNotMatch(maintenance, /Show recent log|Reboot|Power off/);
});

test("inspection omits disabled Tari and keeps configuration separate from measurements", () => {
  const state = { tari: { active: false }, topology: { nodes: [{ id: "tari", label: "Tari node" }, { id: "monerod", label: "Monero", remote: true }], edges: [{ from: "monerod", to: "tari", route: "lan" }] }, network: { height: 0 } };
  const out = renderToString(html`<${Inspect} state=${state} />`);
  assert.doesNotMatch(out, /Tari node|Tari height|monerod → tari/);
  assert.match(out, /Configured paths are not observed traffic or proof of reachability/);
  assert.match(out, /Remote/);
  assert.match(out, /Network height/);
});

test("a support download cannot start before a review and a prepared report", async (t) => {
  const instance = new Maintenance({ state: { control_enabled: true } });
  const request = t.mock.method(globalThis, "fetch", async () => { throw new Error("unexpected request"); });
  await instance.download();
  instance.state.bundle = { id: "old-report" };
  await instance.download();
  assert.equal(request.mock.callCount(), 0);
});
