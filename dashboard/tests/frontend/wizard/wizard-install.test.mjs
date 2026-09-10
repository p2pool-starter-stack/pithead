import assert from "node:assert/strict";
import { test } from "node:test";
import { renderToString } from "../helpers/render.mjs";
import { DISKS, REF, appOn, stateFor, stubServer, stubSetState } from "./wizard-helpers.mjs";

// --- the form matches the install selection --------------------------------------------------

async function appWithPick(chosen, wipe) {
  const { inst, restore } = await appOn([
    stateFor("installer", {
      disks: [
        { name: "sda", size: "1T", model: "M", serial: "S", state: "pithead-with-data" },
        { name: "sdb", size: "1T", model: "M", serial: "S", state: "empty" },
      ],
    }),
  ]);
  inst.setState({ chosen, wipe });
  const out = renderToString(inst.render());
  restore();
  return out;
}

test("keep everything: the whole config half disappears — the survivor config wins", async () => {
  const out = await appWithPick("sda", "keep");
  assert.doesNotMatch(out, /Payout address/);
  assert.doesNotMatch(out, /Dashboard login/);
  assert.doesNotMatch(out, /Advanced/);
  assert.match(out, /keeps everything/);
  assert.match(out, /Reinstall the system — keep everything/);
});

test("keep the blockchains still asks the node questions — kept chains only answer for LOCAL nodes", async () => {
  // A machine with local Monero + REMOTE Tari keeps only the Monero chain; hiding the node
  // sections forced Tari local and re-downloaded the very chain remote mode avoids (bench).
  const out = await appWithPick("sda", "data");
  assert.match(out, /Where does Monero data come from/);
  assert.match(out, /Merge-mine Tari\?/);
  assert.match(out, /First sync/);
  assert.match(out, /Payout address/);
  assert.match(out, /Dashboard login/);
});

test("wipe everything (or an empty disk): the full form asks everything", async () => {
  const all = await appWithPick("sda", "all");
  assert.match(all, /Where does Monero data come from/);
  assert.match(all, /First sync/);
  const empty = await appWithPick("sdb", "keep");
  assert.match(empty, /Payout address/);
});

test("chain size, healthchecks and time zone sit under Advanced, not the first-run form", async () => {
  // Audit-confirmed slim first-run (Home Assistant model): these three are the only appliance
  // questions beyond the DIY CLI's own core shortlist, so they move to day-2, not day-1.
  const all = await appWithPick("sda", "all");
  const advancedAt = all.indexOf("Advanced");
  assert.ok(advancedAt > -1, "Advanced pane should render");
  for (const label of ["Chain size", "Healthchecks.io ping URL", "Time zone"]) {
    const at = all.indexOf(label);
    assert.ok(at > -1, `${label} should still render (day-2 need is real)`);
    assert.ok(at > advancedAt, `${label} should render inside the Advanced pane, not the main form`);
  }
  // The primary form's own headings stay above Advanced, unmoved.
  for (const label of ["Payout address", "Dashboard login", "Alerts"]) {
    assert.ok(all.indexOf(label) < advancedAt, `${label} should stay in the primary form`);
  }
});

test("keep everything submits NO config — only the disk request", async () => {
  const { inst, restore } = await appOn([
    stateFor("installer", {
      disks: [{ name: "sda", size: "1T", model: "M", serial: "S", state: "pithead-with-data" }],
    }),
  ]);
  inst.setState({ chosen: "sda", confirm: "sda", wipe: "keep" });
  let sentBody = null;
  const real = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/submit")) {
      sentBody = String(opts.body);
      return { ok: true, status: 200, json: async () => ({}) };
    }
    return { ok: true, status: 200, json: async () => stateFor("installing"), text: async () => "" };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.doesNotMatch(sentBody, /config=/);
  assert.match(sentBody, /disk=sda/);
  assert.match(sentBody, /wipe=keep/);
  restore();
});

test("submit validates IN PLACE: no view swap, the button narrates, the server moves the page", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.editJson({ target: { value: JSON.stringify({ monero: { wallet_address: "4A" } }) } });
  const real = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (String(url).includes("/submit")) return { ok: true, status: 200, json: async () => ({}) };
    return { ok: true, status: 200, json: async () => stateFor("setup"), text: async () => "" };
  };
  await inst.submit({ preventDefault() {} });
  // Still the form — no optimistic page change (the scroll-jump bug) — with the wait narrated.
  assert.equal(inst.state.stage, "setup");
  assert.equal(inst.state.submitting, true);
  assert.match(renderToString(inst.render()), /Validating…/);
  // The server rejects: the wait ends and the reason shows on the same page.
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => stateFor("setup", { error: "bad wallet" }),
    text: async () => "",
  });
  await inst.loadState();
  globalThis.fetch = real;
  assert.equal(inst.state.submitting, false);
  assert.match(renderToString(inst.render()), /bad wallet/);
  restore();
});

test("the mine-on-this-box choice is a labeled select naming RigForge, default Yes", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  const out = renderToString(inst.render());
  assert.match(out, /Mine on this machine too\?/);
  assert.match(out, /No — this box only coordinates/);
  assert.match(out, /RigForge/);
  restore();
});

test("saying yes promises the built-in miner, never a manual install", async () => {
  // The appliance honours the choice itself now: an operator who answers Yes must not be
  // told to install anything — that instruction pointed at a rig that could never exist
  // on a machine with no shell.
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.editJson({ target: { value: JSON.stringify({ local_miner: { enabled: true } }) } });
  const out = renderToString(inst.render());
  assert.match(out, /Nothing to install/);
  assert.doesNotMatch(out, /install RigForge/i);
  restore();
});

// --- the role select (#797 R3): one page, three shapes ---------------------------------------

test("the role select is the FIRST disclosure, above the disk, reading exactly three names", async () => {
  const { inst, restore } = await appOn([stateFor("installer", { disks: DISKS })]);
  const out = renderToString(inst.render());
  assert.ok(out.indexOf("What is this machine?") < out.indexOf("Install onto"));
  assert.match(out, /Pithead \+ RigForge/);
  assert.match(out, /"rig">RigForge</);
  assert.match(out, /"pithead">Pithead</);
  restore();
});

test("role Pithead + RigForge presets the local-miner switch and keeps the full form", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setRole({ target: { value: "both" } });
  assert.equal(inst.state.cfg.local_miner.enabled, true);
  const out = renderToString(inst.render());
  assert.match(out, /Payout address/); // still Pithead's form — no new UI beyond the select
  assert.match(out, /Nothing to install/); // the preset shows as the live switch's Yes note
  // Back to plain Pithead: the documented default returns — today's config, byte for byte.
  inst.setRole({ target: { value: "pithead" } });
  assert.equal(inst.state.cfg.local_miner.enabled, false);
  restore();
});

test("role RigForge collapses the form to pool, worker, password — none of the coordinator", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setRole({ target: { value: "rig" } });
  const out = renderToString(inst.render());
  assert.match(out, /Pool address/);
  assert.match(out, /Worker name/);
  assert.match(out, /Stratum password/);
  assert.doesNotMatch(out, /Payout address/);
  assert.doesNotMatch(out, /Dashboard login/);
  assert.doesNotMatch(out, /Advanced/);
  assert.doesNotMatch(out, /First sync/);
  restore();
});

test("the rig fields open on the host's discovery, and say when nothing answered", async () => {
  const found = await appOn([
    stateFor("setup", { rig_defaults: { pool: "pithead.local:3333", worker: "hp-tower" } }),
  ]);
  found.inst.setRole({ target: { value: "rig" } });
  assert.equal(found.inst.state.rigPool, "pithead.local:3333");
  assert.equal(found.inst.state.rigWorker, "hp-tower");
  assert.match(renderToString(found.inst.render()), /already filled in/);
  found.restore();
  const none = await appOn([stateFor("setup")]);
  none.inst.setRole({ target: { value: "rig" } });
  assert.match(renderToString(none.inst.render()), /No Pithead answered/);
  none.restore();
});

test("run-from-this-stick appears beside the disks for the rig role ONLY", async () => {
  const { inst, restore } = await appOn([stateFor("installer", { disks: DISKS })]);
  assert.doesNotMatch(renderToString(inst.render()), /Run from this USB stick/);
  inst.setRole({ target: { value: "rig" } });
  const out = renderToString(inst.render());
  assert.match(out, /Run from this USB stick — nothing is erased/);
  // Picking it discloses the rig form with no retype gate — nothing is erased.
  inst.setState({ chosen: "usb" });
  const after = renderToString(inst.render());
  assert.match(after, /Pool address/);
  assert.doesNotMatch(after, /Type the disk name to confirm/);
  assert.match(after, /Validate, then save to this stick/);
  restore();
});

test("a rig submit carries the role and answers — never a config", async () => {
  const { inst, restore } = await appOn([stateFor("installer", { disks: DISKS })]);
  inst.setRole({ target: { value: "rig" } });
  inst.setState({ chosen: "usb", rigPool: "10.0.0.5:3333", rigWorker: "shed-3" });
  let sentBody = null;
  const real = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/submit")) {
      sentBody = String(opts.body);
      return { ok: true, status: 200, json: async () => ({}) };
    }
    return { ok: true, status: 200, json: async () => stateFor("handoff"), text: async () => "" };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.match(sentBody, /role=rig/);
  assert.match(sentBody, /rig_pool=10.0.0.5%3A3333/);
  assert.match(sentBody, /disk=usb/);
  assert.doesNotMatch(sentBody, /config=/);
  restore();
});
