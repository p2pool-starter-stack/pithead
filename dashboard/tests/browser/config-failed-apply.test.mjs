import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve, sep } from "node:path";
import { test } from "node:test";
import { chromium } from "playwright";

// Real ConfigView against a fake host API (#3287). PITHEAD_BROWSER_STATIC lets a
// negative-control run serve the pre-fix module.
const staticRoot = resolve(process.env.PITHEAD_BROWSER_STATIC ||
  new URL("../../mining_dashboard/web/static/", import.meta.url).pathname);
const fixture = `<!doctype html><html><body><div id="fixture"></div>
<script type="module">
import { html, render } from '/static/app/preact.mjs';
import { ConfigView } from '/static/config/configview.mjs';
render(html\`<\${ConfigView} appliance=\${false} />\`, document.getElementById('fixture'));
</script></body></html>`;

function host() {
  const state = { loads: 0, commits: 0, committed: [] };
  const json = (res, code, body) => {
    res.writeHead(code, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
  };
  const body = (req) => new Promise((r) => {
    let s = "";
    req.on("data", (c) => (s += c));
    req.on("end", () => r(s));
  });
  const serve = async (req, res) => {
    if (req.url === "/") {
      res.setHeader("Content-Type", "text/html");
      return res.end(fixture);
    }
    if (req.url === "/api/config") {
      state.loads++;
      return json(res, 200, { monero: { mode: "local" } });
    }
    if (req.url === "/api/control/preview") {
      return json(res, 200, { status: "previewed", id: "p1", changes: [{ flag: "OK", msg: "monero.mode changes" }] });
    }
    if (req.url === "/api/control/commit") {
      state.committed.push(JSON.parse(await body(req)));
      state.commits++;
      return json(res, 200, state.commits === 1
        ? { status: "failed", error: "apply exploded", backup: "/fixture/config.json.bak" }
        : { status: "applied" });
    }
    const path = resolve(staticRoot, "." + req.url.replace(/^\/static/, ""));
    if (!req.url.startsWith("/static/") || !path.startsWith(staticRoot + sep)) {
      res.writeHead(404);
      return res.end();
    }
    readFile(path).then((b) => {
      res.setHeader("Content-Type", "text/javascript");
      res.end(b);
    }).catch(() => { res.writeHead(404); res.end(); });
  };
  return { state, serve };
}

async function failedApply(t) {
  const { state, serve } = host();
  const server = createServer(serve);
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  t.after(() => new Promise((r) => server.close(r)));
  const browser = await chromium.launch();
  t.after(() => browser.close());
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const editor = page.locator("textarea.worker-edit");
  await editor.waitFor();
  const draft = JSON.stringify({ monero: { mode: "remote" } }, null, 2);
  await editor.fill(draft);
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await page.getByRole("button", { name: "Confirm & apply" }).click();
  await page.getByText("apply exploded").waitFor();
  return { page, editor, draft, state, errors };
}

test("Back to the form after a failed apply keeps the draft, marker and allows a retry", {
  timeout: 30000,
}, async (t) => {
  const { page, editor, draft, state, errors } = await failedApply(t);
  const loads = state.loads;
  await page.getByRole("button", { name: "Back to the form", exact: true }).click();
  await editor.waitFor();
  assert.equal(await editor.inputValue(), draft);
  await page.getByRole("button", { name: "Discard edits" }).waitFor();
  assert.equal(state.loads, loads, "Back to the form must not refetch the host configuration");
  // Correct the rejected candidate and retry.
  const fixed = JSON.stringify({ monero: { mode: "local", node: "fixed" } }, null, 2);
  await editor.fill(fixed);
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await page.getByRole("button", { name: "Confirm & apply" }).click();
  await page.getByText("Changes applied").waitFor();
  assert.equal(state.committed.length, 2);
  assert.deepEqual(errors, []);
});

test("Discard draft and reload from host replaces the draft and clears the marker", {
  timeout: 30000,
}, async (t) => {
  const { page, editor, draft, state, errors } = await failedApply(t);
  const loads = state.loads;
  await page.getByRole("button", { name: "Discard draft and reload from host", exact: true }).click();
  await editor.waitFor();
  assert.equal(state.loads, loads + 1);
  assert.notEqual(await editor.inputValue(), draft);
  assert.equal(await page.getByRole("button", { name: "Discard edits" }).count(), 0);
  assert.deepEqual(errors, []);
});
