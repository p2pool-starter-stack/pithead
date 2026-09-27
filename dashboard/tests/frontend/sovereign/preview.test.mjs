import assert from "node:assert/strict";
import { request } from "node:http";
import { test } from "node:test";

import {
  createPreviewServer,
  previewState,
} from "../fixtures/sovereign-preview.mjs";

function rawStatus(port, path) {
  return new Promise((resolve, reject) => {
    request({ host: "127.0.0.1", port, path }, (res) => {
      res.resume();
      res.on("end", () => resolve(res.statusCode));
    })
      .on("error", reject)
      .end();
  });
}

test("previewState is deterministic, synthetic, and supports empty and syncing variants", () => {
  const sample = previewState();
  assert.equal(sample.version.text, "Sample data · local preview");
  assert.equal(sample.hashrate.total, "24.80 kH/s");
  assert.equal(sample.hashrate.p2p_24h, "24.80 kH/s");
  assert.equal(sample.host_ip, "192.0.2.10");
  assert.equal(sample.chart.p2pool.length, 145);
  assert.deepEqual(sample.chart.p2pool.at(-1), { x: 1_735_776_000_000, y: 24_800 });
  assert.equal(sample.earnings.available, true);
  assert.equal(sample.earnings.confirmed.xmr_30d, 0.0096);
  assert.equal(sample.earnings_summary.xmr.partial, false);
  assert.equal(sample.xvb_calc.enabled, false);
  assert.deepEqual(sample.chart.raffle, []);
  assert.equal(sample.update.available, false);
  assert.equal(sample.workers.length, 3);
  assert.ok(sample.workers.some((worker) => worker.status === "offline"));
  assert.deepEqual(previewState("empty").workers, []);
  assert.equal(previewState("sync").syncing, true);
});

test("preview server serves the real shell and state, and rejects writes and unsafe paths", async (t) => {
  const server = createPreviewServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;

  const shell = await fetch(`${base}/?ui=sovereign`);
  assert.equal(shell.status, 200);
  assert.match(await shell.text(), /<title>Pithead Dashboard<\/title>/);
  assert.match(shell.headers.get("content-security-policy"), /default-src 'self'/);
  assert.equal(shell.headers.get("referrer-policy"), "same-origin");

  const state = await (await fetch(`${base}/api/state?fixture=sync`)).json();
  assert.equal(state.syncing, true);
  assert.equal(state.version.text, "Sample data · local preview");

  const referred = await (
    await fetch(`${base}/api/state?range=all`, {
      headers: { referer: `${base}/?ui=sovereign&fixture=empty` },
    })
  ).json();
  assert.deepEqual(referred.workers, []);

  assert.equal((await fetch(`${base}/api/control/preview`, { method: "POST" })).status, 405);
  assert.equal((await fetch(`${base}/static/%E0%A4%A`)).status, 400);
  assert.equal(await rawStatus(server.address().port, "/static/..%2Ftemplates%2Findex.html"), 403);
});
