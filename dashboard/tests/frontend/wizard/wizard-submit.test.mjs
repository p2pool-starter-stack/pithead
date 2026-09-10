import assert from "node:assert/strict";
import { test } from "node:test";
import { Done, RestoreSection, WizardApp } from "../../../mining_dashboard/web/static/wizard/wizard.mjs";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { renderToString } from "../helpers/render.mjs";
import { DISKS, REF, appOn, stateFor, stubServer, stubSetState } from "./wizard-helpers.mjs";

test("an empty pool address is stopped client-side with a named reason", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setRole({ target: { value: "rig" } });
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    fetched = true;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.equal(fetched, false);
  assert.match(inst.state.error, /pool address/);
  restore();
});

test("the rig card with no token and no address is worker and pool only — no login", () => {
  const handoff = { role: "rig", worker: "shed-3", stratum: "stratum+tcp://pithead.local:3333" };
  const card = renderToString(
    html`<${Done} status="" handoff=${handoff} installer=${true} stick=${false} onAck=${() => {}} />`,
  );
  assert.match(card, /shed-3/);
  assert.match(card, /stratum\+tcp:\/\/pithead\.local:3333/);
  assert.match(card, /erase the disk and install/); // the ack still releases the erase
  assert.doesNotMatch(card, /Dashboard password/);
  assert.doesNotMatch(card, /Save this before anything else/);
  const stick = renderToString(
    html`<${Done} status="" handoff=${handoff} installer=${true} stick=${true} onAck=${() => {}} />`,
  );
  assert.doesNotMatch(stick, /erase the disk/); // run-from-stick erases nothing
});

test("after the ack, the rig's done view sends the operator to the coordinator, not a link here", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setRole({ target: { value: "rig" } });
  Object.assign(inst.state, { stage: "done", handoff: null });
  const out = renderToString(inst.render());
  assert.match(out, /miner is starting/);
  assert.match(out, /Workers view/); // a rig has no dashboard of its own to point at
  assert.doesNotMatch(out, /nothing mines yet/); // the boot leg is real now
  assert.doesNotMatch(out, /pulling and starting the stack/);
  restore();
});

test("keep on a preserved disk still collapses everything — the rig role included", async () => {
  const { inst, restore } = await appOn([
    stateFor("installer", {
      disks: [{ name: "sda", size: "1T", model: "M", serial: "S", state: "pithead-with-data" }],
    }),
  ]);
  inst.setRole({ target: { value: "rig" } });
  inst.setState({ chosen: "sda", wipe: "keep" });
  const out = renderToString(inst.render());
  assert.doesNotMatch(out, /Pool address/);
  assert.match(out, /keeps everything/);
  restore();
});

test("before a disk is chosen, the page asks ONLY that", async () => {
  const { inst, restore } = await appOn([
    stateFor("installer", {
      disks: [{ name: "sda", size: "1T", model: "M", serial: "S", state: "pithead-with-data" }],
    }),
  ]);
  const out = renderToString(inst.render());
  assert.match(out, /Choose the disk to install onto/);
  assert.match(out, /Target disk/);
  assert.doesNotMatch(out, /Payout address/);
  assert.doesNotMatch(out, /Type the disk name to confirm/);
  assert.doesNotMatch(out, /<button type="submit"/);
  // Picking the disk reveals the rest.
  inst.setState({ chosen: "sda", wipe: "all" });
  const after = renderToString(inst.render());
  assert.match(after, /Payout address/);
  assert.match(after, /Type the disk name to confirm/);
  restore();
});

// --- restore-at-setup (#909, #786 sub-issue B): the config form's alternative -----------------
// Upload an encrypted backup + its passphrase instead of typing a config. Validation is entirely
// host-side (same "container asks, host decides" split); the client wires the two answers up and
// enforces the size cap it can check without a round trip.

test("restore section: names what a restore does and asks for the archive + passphrase", () => {
  const out = renderToString(
    html`<${RestoreSection} file=${null} passphrase="" onFile=${() => {}} onPassphrase=${() => {}} />`,
  );
  assert.match(out, /Restore from a backup/);
  assert.match(out, /emergency-kit passphrase/);
  assert.match(out, /type="file"/);
  assert.match(out, /type="password"/);
});

test("the setup form offers a toggle into restore mode, and back again", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  const before = renderToString(inst.render());
  assert.match(before, /Restoring an existing Pithead/);
  assert.doesNotMatch(before, /Restore from a backup/);
  inst.setState({ restoreMode: true });
  const during = renderToString(inst.render());
  assert.match(during, /Restore from a backup/);
  assert.doesNotMatch(during, /Payout address/); // the normal form is gone, not just hidden
  assert.match(during, /Back to the setup form/);
  restore();
});

test("restore mode on the installer asks for the disk before revealing the upload fields", async () => {
  const { inst, restore } = await appOn([stateFor("installer", { disks: DISKS })]);
  inst.setState({ restoreMode: true });
  const before = renderToString(inst.render());
  assert.match(before, /Target disk/);
  assert.doesNotMatch(before, /Restore from a backup/);
  inst.setState({ chosen: "nvme0n1" });
  const after = renderToString(inst.render());
  assert.match(after, /Restore from a backup/);
  restore();
});

test("submitRestore refuses with no file chosen, client-side, before any fetch", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setState({ restoreMode: true });
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    fetched = true;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await inst.submitRestore({ preventDefault() {} });
  globalThis.fetch = real;
  assert.equal(fetched, false);
  assert.match(inst.state.error, /Choose a backup archive/);
  restore();
});

test("submitRestore refuses an oversize file client-side, naming the cap", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  const huge = new File([new Uint8Array(10)], "backup.tar.gz.enc");
  Object.defineProperty(huge, "size", { value: 64 * 1024 * 1024 + 1 });
  inst.setState({ restoreMode: true, restoreFile: huge });
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    fetched = true;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await inst.submitRestore({ preventDefault() {} });
  globalThis.fetch = real;
  assert.equal(fetched, false);
  assert.match(inst.state.error, /too large/);
  restore();
});

test("submitRestore posts multipart with the archive and passphrase, then waits like a normal submit", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  const file = new File([new Uint8Array(4)], "backup.tar.gz.enc");
  inst.setState({ restoreMode: true, restoreFile: file, restorePassphrase: "fixture-pw" });
  let sentUrl = null;
  let sentBody = null;
  const real = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/submit-restore")) {
      sentUrl = String(url);
      sentBody = opts.body;
      return { ok: true, status: 200, json: async () => ({}) };
    }
    return { ok: true, status: 200, json: async () => stateFor("done"), text: async () => "" };
  };
  await inst.submitRestore({ preventDefault() {} });
  globalThis.fetch = real;
  assert.match(sentUrl, /\/submit-restore$/);
  assert.ok(sentBody instanceof FormData);
  assert.equal(sentBody.get("archive"), file);
  assert.equal(sentBody.get("passphrase"), "fixture-pw");
  assert.equal(inst.state.submitting, true);
  restore();
});

test("submitRestore on the installer requires a disk and the exact retype, like a normal install", async () => {
  const { inst, restore } = await appOn([stateFor("installer", { disks: DISKS })]);
  const file = new File([new Uint8Array(4)], "backup.tar.gz.enc");
  inst.setState({ restoreMode: true, restoreFile: file });
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    fetched = true;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await inst.submitRestore({ preventDefault() {} });
  assert.equal(fetched, false);
  assert.match(inst.state.error, /Choose the disk/);
  inst.setState({ chosen: "sda", confirm: "wrong" });
  await inst.submitRestore({ preventDefault() {} });
  assert.equal(fetched, false);
  assert.match(inst.state.error, /exactly/);
  globalThis.fetch = real;
  restore();
});

test("a rejected restore returns to restore mode with the reason, not the typed-config form", async () => {
  const { inst, restore } = await appOn([
    stateFor("setup", { error: "wrong passphrase or corrupt archive" }),
  ]);
  inst.setState({ restoreMode: true });
  const out = renderToString(inst.render());
  assert.match(out, /wrong passphrase or corrupt archive/);
  assert.match(out, /Restore from a backup/);
  restore();
});

// --- the token gate: the lockout must read as actionable, not as a dead page -----------------

test("auth: a 429 (lockout) shows the console-token message, not the generic wrong-token one", async () => {
  const inst = new WizardApp({});
  stubSetState(inst);
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: false,
    status: 429,
    json: async () => ({ error: "server-side lockout text" }),
  });
  await inst.auth({ preventDefault() {}, target: undefined });
  globalThis.fetch = real;
  assert.match(inst.state.error, /too many attempts/i);
  assert.match(inst.state.error, /console/i);
});

test("auth: a genuinely dropped connection reads the same as the 429 it raced", async () => {
  // The exact bug: the lockout's exit used to race the response, so the fetch this app makes
  // rejects instead of resolving 429. Uncaught, that was a silent unhandled rejection — the
  // operator just saw the page do nothing.
  const inst = new WizardApp({});
  stubSetState(inst);
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    throw new TypeError("Failed to fetch");
  };
  await inst.auth({ preventDefault() {}, target: undefined });
  globalThis.fetch = real;
  assert.match(inst.state.error, /too many attempts/i);
  assert.match(inst.state.error, /console/i);
});

test("auth: an ordinary wrong token still gets the plain message, not the lockout one", async () => {
  const inst = new WizardApp({});
  stubSetState(inst);
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: false, status: 403, json: async () => ({}) });
  await inst.auth({ preventDefault() {}, target: undefined });
  globalThis.fetch = real;
  assert.equal(inst.state.error, "Wrong token.");
});
