import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve, sep } from "node:path";
import { test } from "node:test";
import { chromium } from "playwright";

const staticRoot = resolve(process.env.PITHEAD_BROWSER_STATIC ||
  new URL("../../mining_dashboard/web/static/", import.meta.url).pathname);
const state = JSON.parse(await readFile(new URL("../frontend/fixtures/state.json", import.meta.url)));
state.control_enabled = false; // Other panels need no host control fixture.
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
draw();
</script></body></html>`;

test("configuration drafts and invalid JSON survive every internal view; marker clears only on reset or applied save", {
  timeout: 60000,
}, async (t) => {
  let reads = 0;
  let releasePreview;
  let delayedPreview = false;
  let commitStatus = "applied";
  const server = createServer(async (req, res) => {
    if (req.url === "/") {
      res.setHeader("Content-Type", "text/html");
      return res.end(fixture);
    }
    if (req.url.startsWith("/api/")) {
      res.setHeader("Content-Type", "application/json");
      if (req.url === "/api/config") { reads++; return res.end(JSON.stringify(config)); }
      if (req.url === "/api/control/preview") {
        if (delayedPreview) await new Promise((resolve) => { releasePreview = resolve; });
        return res.end(JSON.stringify({id:"draft-preview",status:"previewed",changes:[{msg:"Energy cost changed"}]}));
      }
      if (req.url === "/api/control/commit") {
        return res.end(JSON.stringify({status:commitStatus,error:"fixture apply failure"}));
      }
      res.writeHead(404);
      return res.end("{}");
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
  t.after(() => {
    releasePreview?.();
    server.closeAllConnections();
    return new Promise((r) => server.close(r));
  });
  const browser = await chromium.launch();
  t.after(() => browser.close());
  const page = await browser.newPage();
  const errors = [];
  let dialogs = 0;
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("dialog", async (dialog) => { dialogs++; await dialog.dismiss(); });
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const nav = page.getByRole("navigation", {name:"View"});
  const configButton = () => nav.getByRole("button", {name:/^Configuration/});
  const marker = () => nav.getByRole("button", {name:"Configuration — Unsaved changes",exact:true});
  const editor = page.locator(".config-view textarea");
  await page.locator(".config-view summary").filter({hasText:"the configuration this page sends"}).click();
  const original = await editor.inputValue();
  await page.locator(".config-view summary").filter({hasText:/^Energy$/}).click();
  await page.locator('.config-view input[type="number"]').fill("0.18");
  await marker().waitFor();
  const valid = await editor.inputValue();
  assert.equal(JSON.parse(valid).dashboard.energy.cost_per_kwh, 0.18);
  for (const text of [valid, '{"dashboard":']) {
    await editor.fill(text);
    for (const view of ["Simple", "Advanced", "Backup"]) {
      await page.getByRole("button", {name:view,exact:true}).click();
      await marker().waitFor();
      assert.equal(await editor.isVisible(), false);
      await configButton().click();
      assert.equal(await editor.inputValue(), text);
      if (text !== valid) assert.equal(await page.getByRole("button", {name:"Save & preview changes"}).isEnabled(), false);
    }
  }
  assert.equal(reads, 1, "navigation must not reload and overwrite the candidate");
  await page.getByRole("button", {name:"Discard edits",exact:true}).click();
  await marker().waitFor({state:"detached"});
  assert.equal(await editor.inputValue(), original);
  await editor.fill(valid);
  delayedPreview = true;
  await page.getByRole("button", {name:"Save & preview changes"}).click();
  await page.getByRole("button", {name:"Previewing…",exact:true}).waitFor();
  await page.getByRole("button", {name:"Simple",exact:true}).click();
  for (let attempt = 0; !releasePreview && attempt < 100; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.ok(releasePreview, "preview request must reach the fixture within one second");
  releasePreview();
  delayedPreview = false;
  await page.locator(".config-view button").filter({hasText:"Save & preview changes"}).waitFor({state:"attached"});
  await nav.getByRole("button", {name:"Advanced",exact:true}).click();
  assert.equal(await page.getByRole("dialog").count(), 0);
  await configButton().click();
  await page.getByRole("dialog", {name:"Review changes"}).waitFor();
  await marker().waitFor(); // Preview alone has not saved anything.
  await page.getByRole("button", {name:"Cancel",exact:true}).click();
  await marker().waitFor();
  commitStatus = "failed";
  await page.getByRole("button", {name:"Save & preview changes"}).click();
  await page.getByRole("button", {name:"Confirm & apply",exact:true}).click();
  await page.getByRole("button", {name:"Back to the form",exact:true}).waitFor();
  await marker().waitFor();
  await page.getByRole("button", {name:"Back to the form",exact:true}).click();
  await marker().waitFor({state:"detached"});
  await page.locator(".config-view summary").filter({hasText:"the configuration this page sends"}).click();
  await editor.fill(valid);
  commitStatus = "applied";
  await page.getByRole("button", {name:"Save & preview changes"}).click();
  await page.getByRole("button", {name:"Confirm & apply",exact:true}).click();
  await page.getByText("Changes applied — only the affected containers were recreated.").waitFor();
  await marker().waitFor({state:"detached"});
  assert.equal(dialogs, 0, "view navigation must not ask for discard confirmation");
  assert.deepEqual(errors, []);
});
