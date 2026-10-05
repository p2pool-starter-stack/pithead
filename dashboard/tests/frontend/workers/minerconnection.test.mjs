import assert from "node:assert/strict";
import { test } from "node:test";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { ConnectionFields, MinerConnection } from "../../../mining_dashboard/web/static/workers/minerconnection.mjs";
import { Done } from "../../../mining_dashboard/web/static/wizard/stages.mjs";
import { renderToString } from "../helpers/render.mjs";
const connection = { url: "stratum+tcp://pool.test:3333", password_set: true, password: "fixture-secret", tls: true, fingerprint: "a".repeat(64) };
const fields = (c, visible = false) => renderToString(html`<${ConnectionFields} connection=${c} visible=${visible} />`);

test("credentials carry the pool URL, mask/reveal, copy and TLS pin", () => {
  assert.match(fields(connection), /stratum\+tcp:\/\/pool.test:3333/);
  assert.match(fields(connection), /type="password"/);
  assert.match(fields(connection), /Copy password/);
  assert.match(fields(connection), /TLS fingerprint/);
  assert.match(fields(connection, true), /type="text"/);
  assert.match(fields(connection, true), /Hide/);
});
test("no password is explicit, and a LAN dashboard always offers a configured password", () => {
  assert.match(fields({ ...connection, password_set: false, password: "" }), /No stratum password/);
  assert.match(fields(connection), /Copy password/);
});
test("the hand-off distinguishes none and carries a password and TLS fingerprint", () => {
  const handoff = { username: "admin", password: "dashboard-login", dashboard: "https://pool.test", stratum: connection.url, stratum_password: connection.password, stratum_tls: true, stratum_fingerprint: connection.fingerprint };
  const out = renderToString(html`<${Done} handoff=${handoff} />`);
  assert.match(out, /Stratum password/);
  assert.match(out, /fixture-secret/);
  assert.match(out, /a{64}/);
  assert.match(renderToString(html`<${Done} handoff=${{ ...handoff, stratum_password: "" }} />`), /No stratum password/);
});
test("a refused or failed API does not leave stale credentials visible", async () => {
  const original = globalThis.fetch;
  const app = new MinerConnection();
  app.setState = (next) => Object.assign(app.state, next);
  try {
    globalThis.fetch = async (url, opts) => {
      assert.equal(url, "/api/miner-connection");
      assert.equal(opts.cache, "no-store");
      return { ok: true, json: async () => connection };
    };
    await app.load();
    assert.deepEqual(app.state.connection, connection);
    globalThis.fetch = async () => ({ ok: false });
    await app.load();
    assert.equal(app.state.connection, null);
    assert.match(app.state.status, /unavailable/);
  } finally { globalThis.fetch = original; }
});

test("copy uses the actual password and reports clipboard failure", async () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  const app = new MinerConnection();
  app.state.connection = connection;
  app.setState = (next) => Object.assign(app.state, next);
  try {
    Object.defineProperty(globalThis, "navigator", { configurable: true, value: { clipboard: { writeText: async (value) => assert.equal(value, connection.password) } } });
    await app.copy();
    assert.equal(app.state.status, "Password copied.");
    Object.defineProperty(globalThis, "navigator", { configurable: true, value: { clipboard: { writeText: async () => { throw new Error("unavailable"); } } } });
    await app.copy();
    assert.match(app.state.status, /Reveal the password and copy it manually/);
  } finally {
    if (descriptor) Object.defineProperty(globalThis, "navigator", descriptor);
    else delete globalThis.navigator;
  }
});
