import assert from "node:assert/strict";
import { test } from "node:test";
import { App } from "../../../mining_dashboard/web/static/app/components.mjs";
import { initDashboard } from "../../../mining_dashboard/web/static/dashboard.js";
import { BASE, UI } from "../harness.mjs";
import { renderToString } from "../helpers/render.mjs";

test("sustained failures show recovery advice at 60 seconds, clear on success, and reset", async () => {
  let time = 0;
  let fail = false;
  let painted;
  const d = initDashboard({
    doc: { getElementById: () => null, documentElement: { setAttribute() {} } },
    storage: { getItem: () => null },
    href: "https://pithead.test/",
    now: () => time,
    schedule() {},
    renderApp: (p) => { painted = p; },
    fetchFn: async () => {
      if (fail) throw new TypeError("Failed to fetch");
      return { ok: true, json: async () => BASE };
    },
  });
  await d.firstLoad;
  const snapshot = painted.state;
  fail = true;
  await d.tick();
  assert.equal(painted.connected, false);
  assert.equal(painted.recoveryNeeded, false);
  time = 59999;
  await d.tick();
  assert.equal(painted.recoveryNeeded, false);
  time = 60000;
  await d.tick();
  assert.equal(painted.recoveryNeeded, true);
  assert.equal(painted.state, snapshot);
  fail = false;
  await d.tick();
  assert.equal(painted.connected, true);
  assert.equal(painted.recoveryNeeded, false);
  fail = true;
  time = 120000;
  await d.tick();
  assert.equal(painted.recoveryNeeded, false);
});

test("recovery guidance covers syncing, full dashboard and failed initial load", () => {
  for (const state of [null, { ...BASE, syncing: true }, BASE]) {
    const props = { state, connected: false, recoveryNeeded: true, ui: UI };
    const out = renderToString(App(props));
    assert.match(out, /Reload this page or open the same dashboard address in a new tab/);
    assert.match(out, /SHA-256 fingerprint with the current fingerprint on the appliance console/);
    assert.match(out, /openssl x509 -in \/data\/pithead\/data\/tls\/wizard\.crt -noout -fingerprint -sha256/);
    assert.match(out, /Stop if they do not\s+match/);
    assert.match(out, /Accept the replacement only after they match/);
    assert.match(out, /polling will\s+reconnect/);
    assert.match(out, /does not tell this page which failure/);
    assert.doesNotMatch(renderToString(App({ ...props, recoveryNeeded: false })), /SHA-256/);
    assert.doesNotMatch(renderToString(App({ ...props, connected: true })), /SHA-256/);
  }
});
