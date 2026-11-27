import assert from "node:assert/strict";
import { test } from "node:test";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { passwordChoice, StratumPasswordChoice } from "../../../mining_dashboard/web/static/wizard/stratumpassword.mjs";
import { renderToString } from "../helpers/render.mjs";

test("the default declines, and only an explicit yes creates a password", () => {
  const crypto = { getRandomValues: (a) => a.fill(171) };
  assert.equal(passwordChoice(false, "", crypto), "");
  assert.equal(passwordChoice(true, "", crypto), "ab".repeat(12));
  const out = renderToString(html`<${StratumPasswordChoice} value="" onChange=${() => {}} />`);
  assert.match(out, /Enable stratum password\?/);
  assert.match(out, /value="false" checked/);
});

test("retained literal and auto values are preserved until the operator declines", () => {
  for (const value of ["auto", "a-saved-secret"]) {
    assert.equal(passwordChoice(true, value), value);
    assert.equal(passwordChoice(false, value), "");
    const out = renderToString(html`<${StratumPasswordChoice} value=${value} onChange=${() => {}} />`);
    assert.match(out, /value="true" checked/);
    assert.doesNotMatch(out, new RegExp(value));
  }
});
