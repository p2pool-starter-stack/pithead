import assert from "node:assert/strict";
import { test } from "node:test";

import { WizardApp } from "../../../mining_dashboard/web/static/wizard/wizard.mjs";
import { renderToString } from "../helpers/render.mjs";

test("setup chooses hostname, pool and login without questions", () => {
  const app = new WizardApp({});
  for (const host of ["auto", "", "external.test", "garden-box"]) {
    app.state.cfg = { dashboard: { host }, local_miner: { enabled: false } };
    const out = renderToString(app.renderSetup());
    assert.equal(app.state.cfg.dashboard.host, host);
    assert.doesNotMatch(out, /Name this machine|machine_name|P2Pool sidechain|Dashboard login|auth-mode/);
  }
  app.state.role = "rig";
  assert.match(renderToString(app.renderSetup()), /Worker name/);
});

test("keep-everything reinstall does not offer a name it would ignore", () => {
  const app = new WizardApp({});
  Object.assign(app.state, {
    installer: true,
    chosen: "sda",
    disks: [{ name: "sda", state: "pithead-with-data" }],
    wipe: "keep",
  });
  assert.doesNotMatch(renderToString(app.renderSetup()), /Name this machine/);
});

test("ack() carries the applied dashboard address past the server dropping the handoff (#2350)", async () => {
  const app = new WizardApp({});
  app.setState = (patch) => Object.assign(app.state, patch);
  app.state.handoff = { username: "admin", password: "x", dashboard: "https://garden-box.local", stratum: "stratum+tcp://garden-box.local:3333" };
  const original = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (String(url) === "/handoff-ack") return { ok: true };
    // The server has already dropped the handoff by the time this poll lands.
    return { ok: true, json: async () => ({ config: {}, reference: {}, handoff: null }) };
  };
  try {
    await app.ack();
    assert.equal(app.state.handoff, null);
    assert.equal(app.state.savedDashboard, "https://garden-box.local");
  } finally {
    globalThis.fetch = original;
  }
});

test("coordinator submission carries its edited name in dashboard.host", async () => {
  const app = new WizardApp({});
  app.setState = (patch) => Object.assign(app.state, patch);
  app.state.cfg = { dashboard: { host: "garden-box" } };
  app.poll = () => {};
  let sent;
  const original = globalThis.fetch;
  globalThis.fetch = async (_url, options) => {
    sent = JSON.parse(options.body.get("config"));
    return { ok: true };
  };
  try {
    await app.submit({ preventDefault() {} });
    assert.equal(sent.dashboard.host, "garden-box");
  } finally {
    globalThis.fetch = original;
  }
});
