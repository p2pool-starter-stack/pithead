import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve, sep } from "node:path";
import { test } from "node:test";
import { chromium } from "playwright";
import { stopFixture } from "./stop-fixture.mjs";

// Serve the production calculator; an alternate root enables a pre-fix negative control.
const staticRoot = resolve(process.env.PITHEAD_BROWSER_STATIC ||
  new URL("../../mining_dashboard/web/static/", import.meta.url).pathname);
const fixture = `<!doctype html><html><body><div id="fixture"></div>
<script type="module">
import { html, render } from '/static/app/preact.mjs';
import { EarningsCard } from '/static/app/earnings.mjs';
render(html\`<\${EarningsCard} earnings=\${{
  available: true, p2pool_hr: 1000, p2pool_hr_str: '1000 H/s',
  coeff_day: 0.001, pool_difficulty: 1000,
}} />\`, document.getElementById('fixture'));
</script></body></html>`;

function serve(req, res) {
  if (req.url === "/") {
    res.setHeader("Content-Type", "text/html");
    return res.end(fixture);
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

test("earnings calculator converts grouped thousands and rejects malformed hashrate", {
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
  const input = page.getByRole("textbox", { name: "Your P2Pool Hashrate" });
  const coins = page.locator("#epanel-monero .est-table tbody td.c-accent");
  const expected = ["1.0000 XMR", "30.0000 XMR", "365.0000 XMR"];
  // Locator assertions poll the actual rerender, rather than reading stale pre-input text.
  async function expectCoins(values) {
    await page.waitForFunction((wanted) => {
      const cells = [...document.querySelectorAll("#epanel-monero .est-table tbody td.c-accent")];
      return JSON.stringify(cells.map((cell) => cell.textContent)) === JSON.stringify(wanted);
    }, values, { timeout: 3000 }).catch(async () => {
      assert.deepEqual(errors, [], "browser module errors");
      assert.deepEqual(await coins.allTextContents(), values, "calculator coin rows");
      assert.fail("calculator did not settle");
    });
    assert.deepEqual(await coins.allTextContents(), values);
  }
  await expectCoins(expected);
  await input.fill("10");
  await expectCoins(["0.010000 XMR", "0.300000 XMR", "3.650000 XMR"]);
  for (const [value, values] of [
    ["1,000", expected], ["10garbage", ["—", "—", "—"]],
    ["1 kH/s", expected], ["1e3", ["—", "—", "—"]],
  ]) {
    await t.test(value, async () => {
      await input.fill(value);
      await expectCoins(values);
    });
  }
  assert.deepEqual(errors, []);
});
