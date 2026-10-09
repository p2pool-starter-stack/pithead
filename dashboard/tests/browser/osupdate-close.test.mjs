import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve, sep } from "node:path";
import { test } from "node:test";
import { chromium } from "playwright";
import { stopFixture } from "./stop-fixture.mjs";

// Real production component and native dialog, served locally with a refused host check.
// PITHEAD_BROWSER_STATIC lets a negative-control run serve the old implementation.
const staticRoot = resolve(process.env.PITHEAD_BROWSER_STATIC ||
  new URL("../../mining_dashboard/web/static/", import.meta.url).pathname);
const fixture = `<!doctype html><html><body><div id="fixture"></div>
<script type="module">
import { html, render } from '/static/app/preact.mjs';
import { OsUpdateControl } from '/static/system/osupdate.mjs';
render(html\`<\${OsUpdateControl} os=\${{step:'idle'}} enabled=\${true} />\`,
  document.getElementById('fixture'));
</script></body></html>`;

function serve(req, res) {
  if (req.url === "/") {
    res.setHeader("Content-Type", "text/html");
    return res.end(fixture);
  }
  if (req.url === "/api/control/os-update") {
    res.writeHead(202, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ id: "fixture-check" }));
  }
  if (req.url.startsWith("/api/control/result?")) {
    res.setHeader("Content-Type", "application/json");
    return res.end(JSON.stringify({ status: "failed",
      error: "the latest release publishes no appliance OS bundle" }));
  }
  const path = resolve(staticRoot, "." + req.url.replace(/^\/static/, ""));
  if (!req.url.startsWith("/static/") || !path.startsWith(staticRoot + sep)) {
    res.writeHead(404);
    return res.end();
  }
  readFile(path).then((body) => {
    res.setHeader("Content-Type", "text/javascript");
    res.end(body);
  }).catch(() => { res.writeHead(404); res.end(); });
}

test("one error Close dismisses the native dialog and restores focus to OS updates", {
  timeout: 30000,
}, async (t) => {
  const server = createServer(serve);
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  let browser;
  t.after(() => stopFixture(server, browser));
  browser = await chromium.launch();
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const trigger = page.getByRole("button", { name: "OS updates", exact: true });
  await trigger.click();
  const dialog = page.getByRole("dialog", { name: "System update" });
  await dialog.getByRole("button", { name: "Check now", exact: true }).click();
  await dialog.getByText("the latest release publishes no appliance OS bundle").waitFor();
  await dialog.getByRole("button", { name: "Close", exact: true }).click();
  await dialog.waitFor({ state: "detached", timeout: 3000 });
  assert.equal(await trigger.evaluate((node) => document.activeElement === node), true);
  assert.deepEqual(errors, []);
});
