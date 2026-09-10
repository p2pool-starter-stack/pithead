import assert from "node:assert/strict";
import { test } from "node:test";

import { WizardApp } from "../../../mining_dashboard/web/static/wizard/wizard.mjs";
import { renderToString } from "../helpers/render.mjs";

test("coordinators ask for the machine name, rigs retain their worker field", () => {
  const app = new WizardApp({});
  app.setState = (patch) => Object.assign(app.state, patch);
  for (const enabled of [false, true]) {
    app.state.cfg = { local_miner: { enabled }, dashboard: { host: "pithead" } };
    const out = renderToString(app.renderSetup());
    assert.match(out, /Name this machine/);
    assert.match(out, /name="machine_name" value="pithead"/);
    assert.match(out, /maxlength="63"/);
    assert.match(out, /pattern="/);
    const pattern = new RegExp(`^(?:${out.match(/pattern="([^"]+)"/)[1]})$`, "v");
    assert.ok(pattern.test("garden-box"));
    assert.ok(!pattern.test("bad\\name") && !pattern.test("external.test"));
    assert.doesNotMatch(out, /name="rig_worker"/);
  }
  app.edit("dashboard.host")({ target: { value: "garden-box" } });
  assert.equal(JSON.parse(app.state.jsonText).dashboard.host, "garden-box");
  assert.match(renderToString(app.renderSetup()), /value="garden-box"/);
  app.state.role = "rig";
  const rig = renderToString(app.renderSetup());
  assert.doesNotMatch(rig, /Name this machine/);
  assert.match(rig, /Worker name/);
});

test("legacy address and auto are displayed honestly without changing the saved answer", () => {
  const app = new WizardApp({});
  for (const host of ["auto", "", "external.test", "192.0.2.10"]) {
    app.state.cfg = { dashboard: { host } };
    const out = renderToString(app.renderSetup());
    assert.equal(app.state.cfg.dashboard.host, host);
    assert.doesNotMatch(out, /name="machine_name" value="pithead"/);
    if (host === "auto") {
      assert.match(out, /name="machine_name" value="auto"/);
      assert.match(out, /auto keeps the current hostname/);
    } else {
      assert.match(out, /Keeping the saved dashboard address/);
      assert.match(out, /name="machine_name" value=""/);
    }
  }
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
