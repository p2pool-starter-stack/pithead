import { test } from "node:test";
import assert from "node:assert/strict";
import { ConfigView } from "../../../mining_dashboard/web/static/config/configview.mjs";
import { buildSections, editableCandidate } from "../../../mining_dashboard/web/static/config/configlogic.mjs";
import { renderToString } from "../helpers/render.mjs";

test("version is shown read-only, warning explains saving, JSON edits cannot change it", async () => {
  const cfg = { config_version: "9.9.9", _config_version_newer: true, p2pool: { pool: "mini" } };
  assert.equal(Object.hasOwn(editableCandidate(cfg), "config_version"), false);
  assert.equal(buildSections(cfg).flatMap((s) => s.fields).some((f) => f.key === "config_version"), false);
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  const previous = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 200, json: async () => cfg });
  try { await view.load(); } finally { globalThis.fetch = previous; }
  const html = renderToString(view.render());
  assert.match(html, /Config file version 9.9.9/);
  assert.match(html, /Saving is blocked/);
  assert.match(html, /Update the OS/);
  assert.doesNotMatch(view.state.editText, /config_version/);
  view.onJsonInput('{"config_version":"1.0.0","p2pool":{"pool":"main"}}');
  assert.doesNotMatch(view.state.editText, /config_version/);
  assert.equal(Object.hasOwn(view.buildProposed().config, "config_version"), false);
  assert.match(renderToString(view.render()), /Config file version 9.9.9/);
});

test("absent stamp shows unknown without a downgrade warning", () => {
  const view = new ConfigView({});
  Object.assign(view.state, { phase: "form", cfg: {}, candidate: {} });
  const html = renderToString(view.render());
  assert.match(html, /Config file version unknown/);
  assert.doesNotMatch(html, /undefined|Saving is blocked/);
});
