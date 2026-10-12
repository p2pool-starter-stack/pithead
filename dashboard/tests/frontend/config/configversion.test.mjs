import { test } from "node:test";
import assert from "node:assert/strict";
import { ConfigVersion } from "../../../mining_dashboard/web/static/config/configversion.mjs";
import { ConfigView } from "../../../mining_dashboard/web/static/config/configview.mjs";
import { buildSections, editableCandidate } from "../../../mining_dashboard/web/static/config/configlogic.mjs";
import { renderToString } from "../helpers/render.mjs";

test("newer warning remains without version text, saving rejection and stamp filtering remain", async () => {
  const cfg = { config_version: "9.9.9", _config_version_newer: true, p2pool: { pool: "mini" } };
  assert.equal(Object.hasOwn(editableCandidate(cfg), "config_version"), false);
  assert.equal(buildSections(cfg).flatMap((s) => s.fields).some((f) => f.key === "config_version"), false);
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  const previous = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 200, json: async () => cfg });
  try { await view.load(); } finally { globalThis.fetch = previous; }
  const html = renderToString(view.render());
  assert.doesNotMatch(html, /Config file version|9\.9\.9/);
  assert.match(html, /Saving is blocked/);
  assert.match(html, /Update the OS/);
  assert.doesNotMatch(view.state.editText, /config_version/);
  view.onJsonInput('{"config_version":"1.0.0","p2pool":{"pool":"main"}}');
  assert.doesNotMatch(view.state.editText, /config_version/);
  assert.equal(Object.hasOwn(view.buildProposed().config, "config_version"), false);
  assert.doesNotMatch(renderToString(view.render()), /Config file version|9\.9\.9/);
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(url);
    return { ok: true, status: 200, json: async () => ({ status: "rejected", error: "Unknown settings; update the OS before saving." }) };
  };
  try { await view.save(); } finally { globalThis.fetch = previous; }
  assert.deepEqual(calls, ["/api/control/preview"]);
  assert.equal(view.state.phase, "form");
  assert.equal(view.state.preview, null);
  assert.match(view.state.error, /Unknown settings/);
  assert.match(renderToString(view.render()), /Saving is blocked/);
});

for (const [name, cfg] of [
  ["absent stamp", {}],
  ["current stamp", { config_version: "2.0.0", _config_version_newer: false }],
]) {
  test(`${name} renders no version card or version text`, () => {
    assert.equal(ConfigVersion({ cfg }), null);
    const view = new ConfigView({});
    Object.assign(view.state, { phase: "form", cfg, candidate: {} });
    const html = renderToString(view.render());
    assert.doesNotMatch(html, /Config file version|2\.0\.0|unknown|undefined|Saving is blocked/);
  });
}
