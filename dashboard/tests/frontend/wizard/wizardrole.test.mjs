// The setup wizard's role choice (mining_dashboard/web/static/wizard/wizard.mjs): what an unconfigured
// machine opens on (#1830), and the single fact it shares with the built-in-miner switch
// (#1831). A sibling of wizard.test.mjs rather than more rows inside it: that file sits at its
// recorded ceiling in docs/dev/file-budget.tsv, and ceilings only go down.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import { WizardApp } from "../../../mining_dashboard/web/static/wizard/wizard.mjs";
import { renderToString } from "../helpers/render.mjs";

// The published reference as a real machine has it: config.reference.json carries
// local_miner.enabled and documents it OFF (#593), which is what the CLI wizard keeps.
const REF = {
  monero: { wallet_address: "", prune: true },
  p2pool: { pool: "mini" },
  local_miner: { enabled: false },
};
const cfgFor = (enabled) => ({
  monero: { wallet_address: "", prune: true },
  p2pool: { pool: "mini" },
  local_miner: { enabled },
});

// A mounted wizard sitting on a given config. The server round trip is deliberately not driven
// here — loadState's own behaviour is asserted in wizard.test.mjs, and what the SERVER publishes
// for an unconfigured machine is pinned at its own tier in tests/web/test_wizard_role.py.
function appOn(cfg) {
  const inst = new WizardApp({});
  inst.setState = (patch) =>
    Object.assign(inst.state, typeof patch === "function" ? patch(inst.state) : patch);
  Object.assign(inst.state, {
    stage: "setup",
    cfg,
    reference: REF,
    jsonText: JSON.stringify(cfg, null, 2),
  });
  return inst;
}

const checked = (out, name, value) =>
  new RegExp(`<input type="radio" name="${name}" value="${value}" checked`).test(out);

test("a machine whose config has the miner on opens on Pithead + RigForge (#1830)", () => {
  const out = renderToString(appOn(cfgFor(true)).render());
  assert.ok(checked(out, "role", "both"));
  assert.match(out, /Nothing to install/); // the switch's own Yes note — the same fact
});

test("a machine whose config keeps the miner off opens on Pithead (#1830 control)", () => {
  // The control that shows the row above can say something else. It is also the real case: a
  // pre-seed, a reinstall pre-fill and a rejected submission all arrive with their own config
  // and win whole over the page's default (tests/web/test_wizard_role.py pins that half).
  const out = renderToString(appOn(cfgFor(false)).render());
  assert.ok(checked(out, "role", "pithead"));
  assert.doesNotMatch(out, /Nothing to install/);
});

test("the (default) marker names the option an unconfigured machine opens on (#1830)", () => {
  // wizard.py:246 publishes local_miner.enabled true for a machine with no previous config, so
  // the marker belongs on Yes. Nothing else on this page pins any marker's POSITION: the row in
  // wizard.test.mjs asserts option text that survives moving the marker back, so a straight
  // revert of the fix ships green (measured by the non-author reviewer at this head).
  const out = renderToString(appOn(cfgFor(true)).render());
  const group = out.match(/Mine on this machine too\?<\/legend>([\s\S]*?)<\/fieldset>/);
  assert.ok(group, "the mine-on-this-machine choices did not render");
  assert.ok(checked(out, "local-miner", "true"));
  assert.match(group[1].match(/value="true"[\s\S]*?<\/label>/)[0], /\bdefault\b/);
  assert.doesNotMatch(group[1].match(/value="false"[\s\S]*?<\/label>/)[0], /\bdefault\b/);
});

test("the miner switch moves the role choice, and so does the JSON pane (#1831)", () => {
  const inst = appOn(cfgFor(false));
  // The switch is the plain field edit the rendered radio group is bound to (FIELDS.localMiner).
  inst.edit("local_miner.enabled")({ target: { value: "true" } });
  assert.ok(checked(renderToString(inst.render()), "role", "both"));
  inst.edit("local_miner.enabled")({ target: { value: "false" } });
  assert.ok(checked(renderToString(inst.render()), "role", "pithead"));
  // Hand-edited JSON wins the same way, because it is the same one fact.
  inst.editJson({ target: { value: JSON.stringify(cfgFor(true)) } });
  assert.ok(checked(renderToString(inst.render()), "role", "both"));
});

test("picking rig IS stored, and outranks whatever the config's miner switch says (#1831)", () => {
  // A rig carries no config at all, so it is the one answer that cannot be read out of one.
  const inst = appOn(cfgFor(true));
  inst.setRole({ target: { value: "rig" } });
  assert.equal(inst.state.role, "rig");
  assert.ok(checked(renderToString(inst.render()), "role", "rig"));
  assert.equal(inst.state.cfg.local_miner.enabled, true); // untouched: a rig never edits config
  // Back to a coordinator: nothing is stored, and the config answers again.
  inst.setRole({ target: { value: "pithead" } });
  assert.equal(inst.state.role, "");
  assert.equal(inst.state.cfg.local_miner.enabled, false);
  assert.ok(checked(renderToString(inst.render()), "role", "pithead"));
});
