import assert from "node:assert/strict";
import { test } from "node:test";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { AdvancedDrawer, Shell } from "../../../mining_dashboard/web/static/sovereign/shell.mjs";
import { PAGES } from "../../../mining_dashboard/web/static/sovereign/navigation.mjs";
import { profileBadge, stackStatus } from "../../../mining_dashboard/web/static/sovereign/status.mjs";
import { renderToString } from "../helpers/render.mjs";

test("all pages and platform fixtures retain shell, profile and fresh or unknown status", () => {
  for (const page of Object.keys(PAGES)) for (const platform of ["appliance", "diy-login", "diy-readonly"]) {
    const state = { version: { text: "2.1" }, control_enabled: platform !== "diy-readonly", os_update: platform === "appliance" ? {} : null,
      host_ip: "private-host", last_update: "sample time", monero: { health: { level: "green" } }, profile: { name: "Balance" } };
    const out = renderToString(html`<${Shell} route=${{ page, advanced: null }} url="https://example.test/ui-preview" state=${state} connected=${true} />`);
    assert.match(out, /Healthy/);
    assert.match(out, /Balance: Everything goes through Tor/);
    assert.match(out, new RegExp(PAGES[page][1].replace(/[?]/g, "\\?")));
    assert.match(out, /sample time/);
    assert.doesNotMatch(out, /private-host/);
    assert.equal((out.match(/aria-current="page"/g) || []).length, 1);
    assert.equal((out.match(/<button/g) || []).length, 2);
  }
});

test("unknown, zero, sync and disconnected snapshots have different status", () => {
  assert.equal(stackStatus(null, true).level, "unknown");
  assert.equal(stackStatus({}, true).text, "Health unknown");
  assert.equal(stackStatus({ syncing: true, sync: { monero: { percent: 0 } } }, true).text, "Syncing 0%");
  assert.equal(stackStatus({ db_healthy: false }, true).text, "Needs attention 1");
  assert.equal(stackStatus({}, false).text, "Disconnected");
  assert.equal(profileBadge(null), "Profile not reported");
  assert.match(profileBadge({ name: "Privacy", customized: true }), /Privacy \(customized\): Tor only, rigs locked/);
});

test("Advanced keeps a direct accessible name across section changes", () => {
  const out = renderToString(html`<${AdvancedDrawer} section="appearance" theme="auto" />`);
  assert.match(out, /<dialog class="advanced" aria-label="Advanced"/);
  assert.doesNotMatch(out, /aria-labelledby=/);
});

test("Appearance has an exact Theme label independent of option text", () => {
  const out = renderToString(html`<${AdvancedDrawer} section="appearance" theme="auto" />`);
  assert.match(out, /<label for="sovereign-theme">Theme<\/label>/);
  assert.match(out, /<select id="sovereign-theme" value="auto"/);
  assert.match(out, /Follow operating system/);
});
