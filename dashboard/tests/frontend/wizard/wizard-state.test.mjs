import assert from "node:assert/strict";
import { test } from "node:test";
import { renderToString } from "../helpers/render.mjs";
import { REF, appOn, stateFor, stubServer, stubSetState } from "./wizard-helpers.mjs";

test("loadState maps every server stage onto the view it should render", async () => {
  for (const [serverStage, viewStage] of [
    ["setup", "setup"],
    ["installer", "setup"], // the combined form: same view, installer flag set
    ["installing", "installing"],
    ["handoff", "done"],
    ["done", "done"],
  ]) {
    const { inst, restore } = await appOn([stateFor(serverStage)]);
    assert.equal(inst.state.stage, viewStage, `${serverStage} -> ${viewStage}`);
    assert.equal(inst.state.installer, serverStage === "installer", `${serverStage} installer flag`);
    restore();
  }
});

test("an unknown server stage falls back to setup rather than a blank screen", async () => {
  const { inst, restore } = await appOn([stateFor("something-new")]);
  assert.equal(inst.state.stage, "setup");
  restore();
});

test("the handoff arrives through the SAME poll and reaches the view", async () => {
  // The exact bug: the card must appear without a second, separately-raced fetch.
  const handoff = { username: "admin", password: "p".repeat(32), dashboard: "https://x", stratum: "s" };
  const { inst, restore } = await appOn([
    stateFor("done"), // provisioning started, nothing published yet
    stateFor("handoff", { handoff }), // then credentials appear
  ]);
  assert.equal(inst.state.handoff, null);
  await inst.loadState();
  assert.equal(inst.state.stage, "done");
  assert.equal(inst.state.handoff.password.length, 32);
  // And the view actually renders the card from that state — the end of the chain.
  assert.match(renderToString(inst.render()), /Save this before anything else/);
  restore();
});

test("a refresh mid-provision does not walk back into an editable form", async () => {
  const { inst, restore } = await appOn([stateFor("done")]);
  const out = renderToString(inst.render());
  assert.doesNotMatch(out, /Monero payout address/);
  assert.match(out, /stop responding/);
  restore();
});

test("a host rejection returns to the form with the reason and the submitted answers", async () => {
  const attempted = { monero: { wallet_address: "4TYPO" }, p2pool: { pool: "mini" } };
  const { inst, restore } = await appOn([
    stateFor("setup", { config: attempted, error: "bad wallet" }),
  ]);
  assert.equal(inst.state.stage, "setup");
  assert.equal(inst.state.error, "bad wallet");
  const out = renderToString(inst.render());
  assert.match(out, /bad wallet/);
  assert.match(out, /4TYPO/); // no retyping a 95-character address
  restore();
});

test("in-progress edits are not clobbered by a later poll of the server's copy", async () => {
  // The form polls while open; the operator's half-typed address must survive it.
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.editJson({
    target: {
      value: JSON.stringify({ monero: { wallet_address: "4MINE" }, p2pool: { pool: "nano" } }),
    },
  });
  await inst.loadState();
  assert.equal(inst.state.cfg.monero.wallet_address, "4MINE");
  assert.equal(inst.state.cfg.p2pool.pool, "nano");
  restore();
});

test("submit carries the auth-mode choice beside the config", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setState({ authMode: "none" });
  let sentBody = null;
  const real = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/submit")) {
      sentBody = String(opts.body);
      return { ok: true, status: 200, json: async () => ({}) };
    }
    return { ok: true, status: 200, json: async () => stateFor("done"), text: async () => "" };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.match(sentBody, /auth_mode=none/);
  assert.match(sentBody, /config=/);
  restore();
});

test("on the installation medium, ONE submit carries config, disk, confirmation and wipe", async () => {
  const { inst, restore } = await appOn([stateFor("installer")]);
  inst.setState({ chosen: "sda", confirm: "sda", wipe: "data" });
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
  assert.match(sentBody, /config=/);
  assert.match(sentBody, /disk=sda/);
  assert.match(sentBody, /confirm=sda/);
  assert.match(sentBody, /wipe=data/);
  restore();
});

test("the erase is blocked client-side until the disk name is retyped exactly", async () => {
  const { inst, restore } = await appOn([stateFor("installer")]);
  inst.setState({ chosen: "sda", confirm: "sd" });
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    fetched = true;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.equal(fetched, false);
  assert.match(inst.state.error, /exactly/);
  restore();
});
