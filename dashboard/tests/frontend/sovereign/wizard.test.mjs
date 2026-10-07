import assert from "node:assert/strict";
import { test } from "node:test";

import { renderToString } from "../helpers/render.mjs";
import { WizardApp } from "../../../mining_dashboard/web/static/wizard/wizard.mjs";
import { wizardProgress } from "../../../mining_dashboard/web/static/wizard/sovereign.mjs";

function app(sovereign, state) {
  const instance = new WizardApp({ sovereign });
  instance.setState = (patch) => Object.assign(instance.state, patch);
  instance.setState(state);
  return instance;
}

test("Sovereign progress follows the server-owned stage", () => {
  assert.deepEqual(wizardProgress({ stage: "gate" }), {
    step: 0,
    title: "Your machine. Your keys.",
    note: "Start with the one-time token on this machine's console.",
  });
  assert.equal(wizardProgress({ stage: "setup" }).step, 1);
  assert.equal(wizardProgress({ stage: "setup", restoreMode: true }).title, "Bring your operation home.");
  assert.equal(
    wizardProgress({ stage: "setup", savedRole: { role: "rig" }, setUpAgain: false }).title,
    "Welcome back.",
  );
  assert.equal(wizardProgress({ stage: "done", handoff: {} }).step, 2);
  for (const stage of ["installing", "failed", "done"]) {
    assert.equal(wizardProgress({ stage }).step, 3, stage);
  }
});

test("Sovereign framing preserves the install disk retype used by the classic wizard", () => {
  const state = {
    stage: "setup",
    installer: true,
    cfg: {},
    disks: [
      {
        name: "preview-data",
        size: "3.6T",
        model: "Sample disk",
        serial: "SAMPLE-DATA",
        state: "pithead-with-data",
      },
    ],
    chosen: "preview-data",
    confirm: "preview-data",
    wipe: "keep",
  };
  const classic = renderToString(app(false, structuredClone(state)).render());
  const sovereign = renderToString(app(true, structuredClone(state)).render());

  for (const output of [classic, sovereign]) {
    assert.match(output, /Type the disk name to confirm/);
    assert.match(output, /value="preview-data"/);
  }
  assert.equal((sovereign.match(/<h1/g) || []).length, 1);
});

test("Sovereign framing preserves the one-time credential acknowledgement", () => {
  const state = {
    stage: "done",
    installer: true,
    handoff: {
      username: "sample-admin",
      password: "SAMPLE-ONLY-NOT-A-REAL-PASSWORD",
      dashboard: "https://sample-device.invalid",
      stratum: "stratum+tcp://sample-device.invalid:3333",
    },
  };
  const classicApp = app(false, structuredClone(state));
  const sovereignApp = app(true, structuredClone(state));
  const classicView = classicApp.render();
  const sovereignView = sovereignApp.render();
  const classic = renderToString(classicView);
  const sovereign = renderToString(sovereignView);

  for (const output of [classic, sovereign]) {
    assert.match(output, /SAMPLE-ONLY-NOT-A-REAL-PASSWORD/);
    assert.match(output, /I saved these — erase the disk and install/);
  }
  assert.equal(classicView.props.onAck, classicApp.ack);
  assert.equal(sovereignView.props.children.props.onAck, sovereignApp.ack);
  assert.equal((sovereign.match(/<h1/g) || []).length, 1);
});
