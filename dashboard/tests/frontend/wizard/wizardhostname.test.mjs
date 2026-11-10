import assert from "node:assert/strict";
import { test } from "node:test";

import { WizardApp } from "../../../mining_dashboard/web/static/wizard/wizard.mjs";
import { renderToString } from "../helpers/render.mjs";

test("coordinators ask for the machine name, rigs name themselves by their worker", () => {
  const app = new WizardApp({});
  app.setState = (patch) => Object.assign(app.state, patch);
  for (const enabled of [false, true]) {
    app.state.cfg = { local_miner: { enabled }, dashboard: { host: "pithead" } };
    const out = renderToString(app.renderSetup());
    assert.match(out, /Name this machine/);
    assert.doesNotMatch(out, /P2Pool sidechain|Dashboard login|auth-mode/);
    assert.match(out, /name="machine_name" value="pithead"/);
    assert.match(out, /maxlength="63"/);
    assert.match(out, /pattern="/);
    const pattern = new RegExp(`^(?:${out.match(/pattern="([^"]+)"/)[1]})$`, "v");
    assert.ok(pattern.test("garden-box"));
    assert.ok(!pattern.test("bad\\name") && !pattern.test("external.test"));
    assert.ok(!pattern.test("Garden") && !pattern.test("-box") && !pattern.test("box-"));
    assert.doesNotMatch(out, /name="rig_worker"/);
  }
  app.edit("dashboard.host")({ target: { value: "garden-box" } });
  assert.equal(JSON.parse(app.state.jsonText).dashboard.host, "garden-box");
  assert.match(renderToString(app.renderSetup()), /value="garden-box"/);
  app.state.role = "rig";
  const rig = renderToString(app.renderSetup());
  assert.doesNotMatch(rig, /name="machine_name"/);
  assert.match(rig, /Name this machine \(its worker name\)/);
  assert.doesNotMatch(rig, /lowercase letters/);
  app.state.rigWorker = "Shed_3";
  assert.match(renderToString(app.renderSetup()), /lowercase letters, digits or hyphens/);
  app.state.rigWorker = "shed-3";
  assert.doesNotMatch(renderToString(app.renderSetup()), /lowercase letters/);
});

test("legacy addresses are displayed honestly, and auto and localhost refuse as names", () => {
  const app = new WizardApp({});
  for (const host of ["", "external.test", "192.0.2.10"]) {
    app.state.cfg = { dashboard: { host } };
    const out = renderToString(app.renderSetup());
    assert.equal(app.state.cfg.dashboard.host, host);
    assert.doesNotMatch(out, /name="machine_name" value="pithead"/);
    assert.match(out, /Keeping the saved dashboard address/);
    assert.match(out, /name="machine_name" value=""/);
  }
  for (const host of ["auto", "localhost", "Garden", "-box", "box-"]) {
    app.state.cfg = { dashboard: { host } };
    const out = renderToString(app.renderSetup());
    assert.equal(app.state.cfg.dashboard.host, host);
    assert.match(out, /class="c-bad"[^>]*role="alert"/);
    assert.match(
      out,
      /Name this machine: 1–63 lowercase letters, digits or hyphens, starting and ending with a letter or digit; auto and localhost are reserved/
    );
  }
  for (const host of ["pithead", "garden-box"]) {
    app.state.cfg = { dashboard: { host } };
    assert.doesNotMatch(renderToString(app.renderSetup()), /class="c-bad"[^>]*role="alert"/);
  }
});

test("machineNameError keeps the wizard's rule honest", async () => {
  const { machineNameError } = await import(
    "../../../mining_dashboard/web/static/wizard/wizardhostname.mjs"
  );
  for (const bad of ["", "auto", "localhost", "Box", "a b", "a".repeat(64), "-x", "x-", "a.b"]) {
    assert.ok(machineNameError(bad), `refuses ${JSON.stringify(bad)}`);
  }
  for (const good of ["a", "pithead", "garden-box", "9x", "x".repeat(63)]) {
    assert.equal(machineNameError(good), "", `accepts ${good}`);
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
