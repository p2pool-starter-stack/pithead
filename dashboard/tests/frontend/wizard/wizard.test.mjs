import assert from "node:assert/strict";
import { test } from "node:test";
import { Done, Gate, Installing, InstallSection } from "../../../mining_dashboard/web/static/wizard/wizard.mjs";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { renderToString } from "../helpers/render.mjs";
import { DISKS } from "./wizard-helpers.mjs";

const sect = (props) =>
  renderToString(
    html`<${InstallSection} disks=${DISKS} chosen="" confirm="" wipe="keep"
      onPick=${() => {}} onConfirm=${() => {}} onWipe=${() => {}} ...${props} />`,
  );

test("gate: says the token is case- and prefix-forgiving", () => {
  const out = renderToString(html`<${Gate} error="" onSubmit=${() => {}} />`);
  assert.match(out, /Case doesn't matter/);
  assert.match(out, /pit-/);
});

test("picker: the consequence sits before the truncation point, per disk state", () => {
  const out = sect({});
  // A <select> truncates on the right; bench screenshots cut off exactly the erase/keep words.
  assert.ok(out.indexOf("nvme0n1 — ERASES everything on it") < out.indexOf("931.5G"));
  assert.ok(out.indexOf("sda — holds a previous install") < out.indexOf("3.6T"));
  // Model and serial show — a bare /dev/sda is not enough to choose safely.
  assert.match(out, /Samsung SSD 990/);
  assert.match(out, /S6P1NF0T/);
});

test("picker: an empty disk restates the erase in red, and offers NO wipe choice", () => {
  const destructive = sect({ chosen: "nvme0n1" });
  assert.match(destructive, /Installing to nvme0n1 — this ERASES everything on it/);
  assert.match(destructive, /c-bad/);
  assert.doesNotMatch(destructive, /Keep my data/);
});

test("picker: a previous install offers the three-way data choice as a dropdown", () => {
  const out = sect({ chosen: "sda" });
  assert.match(out, /Keep everything/);
  assert.match(out, /keep the blockchains/);
  assert.match(out, /Wipe everything/);
  // The expensive consequence is named where the choice is made, not discovered later.
  assert.match(out, /re-download from scratch/);
  // Not yet the red warning — that appears only once "all" is chosen.
  assert.doesNotMatch(out, /took days to download/);
});

test("picker: choosing 'wipe everything' surfaces the red consequence line", () => {
  const out = sect({ chosen: "sda", wipe: "all" });
  assert.match(out, /took days to download/);
  assert.match(out, /c-bad/);
});

test("installing: the completion is the shutdown, steps in un-swappable order", () => {
  const out = renderToString(html`<${Installing} status="Installed — the machine…" />`);
  assert.ok(out.indexOf("switch itself off") < out.indexOf("Remove the USB stick"));
  assert.ok(out.indexOf("Remove the USB stick") < out.indexOf("Switch it back on"));
});

test("done without a handoff yet: names the dark period and where the dashboard appears", () => {
  // Before the host publishes credentials (or on the fallback timeout), the page must already
  // say that going unresponsive IS the machine working — a bench session read the dark period
  // as a crash.
  const out = renderToString(html`<${Done} status="" handoff=${null} acked=${false} onAck=${() => {}} />`);
  assert.match(out, /stop responding/);
  assert.match(out, /pithead\.local/);
});

test("handoff card: credentials shown once, provisioning gated on the ack", () => {
  const handoff = {
    username: "admin",
    password: "fixture-password-render-test-only",
    dashboard: "https://pithead.local",
    stratum: "stratum+tcp://pithead.local:3333",
  };
  const card = renderToString(html`<${Done} status="" handoff=${handoff} onAck=${() => {}} />`);
  assert.match(card, /Save this before anything else/);
  assert.match(card, /fixture-password-render-test-only/);
  assert.match(card, /stratum\+tcp:\/\/pithead\.local:3333/);
  assert.match(card, /I saved these/);
  // Once the SERVER drops out of the handoff stage it stops sending the card, and the view
  // shows the dark-period notice instead — a dead tab must read as the machine working.
  const dark = renderToString(html`<${Done} status="" handoff=${null} onAck=${() => {}} />`);
  assert.match(dark, /stop responding/);
  assert.match(dark, /pithead\.local/);
});
