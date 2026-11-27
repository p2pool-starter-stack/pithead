import assert from "node:assert/strict";
import { test } from "node:test";
import { WizardApp } from "../../../mining_dashboard/web/static/wizard/wizard.mjs";
import { renderToString } from "../helpers/render.mjs";
import { stubSetState } from "./wizard-helpers.mjs";

function app() {
  const inst = new WizardApp({});
  stubSetState(inst);
  inst.setState({ stage: "setup" });
  return inst;
}

for (const text of [
  '{"monero":{},"monero":{"wallet_address":"private-value"}}',
  '{"monero":{"mode":"local","mode":"remote"}}',
]) {
  test(`the JSON pane refuses duplicate members: ${text}`, () => {
    const inst = app();
    const before = inst.state.cfg;
    inst.editJson({ target: { value: text } });
    assert.match(inst.state.jsonError, /duplicate key/);
    assert.doesNotMatch(inst.state.jsonError, /private-value/);
    assert.equal(inst.state.jsonText, text);
    assert.equal(inst.state.cfg, before);
    assert.match(renderToString(inst.render()), /disabled/);
  });
}

test("a corrected JSON document clears the error and updates the form", () => {
  const inst = app();
  inst.editJson({ target: { value: '{"p2pool":{},"p2pool":{}}' } });
  const cfg = { monero: { mode: "local", clearnet_initial_sync: true }, p2pool: { pool: "mini" } };
  inst.editJson({ target: { value: JSON.stringify(cfg) } });
  assert.equal(inst.state.jsonError, "");
  assert.deepEqual(inst.state.cfg, cfg);
  assert.equal(inst.state.fastSync, true);
  assert.equal(inst.state.tariTouched, true);
});

for (const text of ["", "{", "null", "[]", "42"]) {
  test(`the JSON pane requires a complete object: ${JSON.stringify(text)}`, () => {
    const inst = app();
    inst.editJson({ target: { value: text } });
    assert.ok(inst.state.jsonError);
  });
}
