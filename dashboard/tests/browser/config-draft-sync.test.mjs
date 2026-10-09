import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve, sep } from "node:path";
import { test } from "node:test";
import { chromium } from "playwright";

const staticRoot = resolve(process.env.PITHEAD_BROWSER_STATIC ||
  new URL("../../mining_dashboard/web/static/", import.meta.url).pathname);
const state = JSON.parse(await readFile(new URL("../frontend/fixtures/state.json", import.meta.url)));
state.control_enabled = false;
const config = {
  dashboard: { energy: { cost_per_kwh: 0.17 } },
  _editable_keys: ["dashboard.energy.cost_per_kwh"],
};
const fixture = `<!doctype html><html><body><div id="fixture"></div>
<script type="module">
import { html, render } from '/static/app/preact.mjs';
import { App } from '/static/app/components.mjs';
const state = ${JSON.stringify(state)};
const ui = {view:'config',range:'all',series:{},avg:'10m',theme:'auto',hintDismissed:true};
const draw = () => render(html\`<\${App} state=\${state} connected=\${true} ui=\${ui}
  onView=\${mode => {ui.view = mode; draw();}} />\`, document.getElementById('fixture'));
window.setSyncing = (syncing) => { state.syncing = syncing; draw(); };
draw();
</script></body></html>`;

test("a configuration draft survives a synchronization screen and keeps its marker", { timeout: 60000 }, async (t) => {
  let reads = 0;
  const server = createServer(async (req, res) => {
    if (req.url === "/") {
      res.setHeader("Content-Type", "text/html");
      return res.end(fixture);
    }
    if (req.url === "/api/config") {
      reads++;
      res.setHeader("Content-Type", "application/json");
      return res.end(JSON.stringify(config));
    }
    const path = resolve(staticRoot, "." + req.url.replace(/^\/static/, ""));
    if (!req.url.startsWith("/static/") || !path.startsWith(staticRoot + sep)) {
      res.writeHead(404); return res.end();
    }
    try {
      res.setHeader("Content-Type", "text/javascript");
      res.end(await readFile(path));
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  t.after(() => { server.closeAllConnections(); return new Promise((r) => server.close(r)); });
  const browser = await chromium.launch();
  t.after(() => browser.close());
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const nav = page.getByRole("navigation", {name:"View"});
  const marker = () => nav.getByRole("button", {name:"Configuration — Unsaved changes",exact:true});
  const editor = page.locator(".config-view textarea");
  await page.locator(".config-view summary").filter({hasText:"the configuration this page sends"}).click();
  await page.locator(".config-view summary").filter({hasText:/^Energy$/}).click();
  await page.locator('.config-view input[type="number"]').fill("0.18");
  await marker().waitFor();
  const draft = await editor.inputValue();
  await page.evaluate(() => window.setSyncing(true));
  await page.locator(".progress-text").first().waitFor();
  assert.equal(await editor.isVisible(), false, "the draft is hidden while the sync screen shows");
  await page.evaluate(() => window.setSyncing(false));
  await marker().waitFor();
  assert.equal(await editor.inputValue(), draft);
  assert.equal(reads, 1, "a sync transition must not reload and overwrite the candidate");
  assert.deepEqual(errors, []);
});
