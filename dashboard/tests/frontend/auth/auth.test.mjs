import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { test } from "node:test";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { renderToString } from "../helpers/render.mjs";

const staticRoot = resolve(
  process.env.PITHEAD_AUTH_STATIC || resolve(import.meta.dirname, "../../../mining_dashboard/web/static"),
);
const load = (path) => import(pathToFileURL(resolve(staticRoot, path)));
const accountPassword = randomBytes(18).toString("base64url");
const metricsPassword = randomBytes(18).toString("base64url");

test("signed-in account exposes role and same-origin sign out", async () => {
  const { Account } = await load("app/account.mjs");
  const out = renderToString(html`<${Account} auth=${{ enabled: true, user: "fixture-viewer", role: "viewer" }} />`);
  assert.match(out, /fixture-viewer/);
  assert.match(out, /Read-only/);
  assert.match(out, /<form method="post" action="\/logout">/);
  assert.doesNotMatch(renderToString(html`<${Account} auth=${{ enabled: false }} />`), /logout/);
});

test("password reset sends plaintext only to the hash endpoint and stores the returned hash", async () => {
  const { AuthUsersEditor } = await load("config/authusers.mjs");
  const originalFetch = globalThis.fetch;
  let request;
  globalThis.fetch = async (url, options) => {
    request = { url, options };
    return { ok: true, json: async () => ({ password_hash: "$2b$fixture-hash" }) };
  };
  try {
    let users = [{ name: "fixture-admin", role: "admin", password_hash: { __secret__: true } }];
    const editor = new AuthUsersEditor({ users, onChange: (next) => { users = next; editor.props.users = next; } });
    editor.setState = (next) => { editor.state = { ...editor.state, ...next }; };
    editor.state.passwords = { 0: accountPassword };
    await editor.resetPassword(0);
    assert.equal(request.url, "/api/auth/hash");
    assert.equal(request.options.headers["X-Pithead-Control"], "1");
    assert.deepEqual(JSON.parse(request.options.body), { password: accountPassword });
    assert.equal(users[0].password_hash, "$2b$fixture-hash");
    assert.equal(editor.state.passwords[0], "");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("monitoring password uses the same hash boundary", async () => {
  const { AuthUsersEditor } = await load("config/authusers.mjs");
  const originalFetch = globalThis.fetch;
  let request;
  globalThis.fetch = async (url, options) => {
    request = { url, options };
    return { ok: true, json: async () => ({ password_hash: "$2b$fixture-metrics-hash" }) };
  };
  try {
    let passwordHash;
    const editor = new AuthUsersEditor({
      users: [],
      onChange() {},
      onMetricsChange: (value) => {
        passwordHash = value;
      },
    });
    editor.setState = (next) => {
      editor.state = { ...editor.state, ...next };
    };
    editor.state.metricsPassword = metricsPassword;
    await editor.setMetricsPassword();
    assert.equal(request.url, "/api/auth/hash");
    assert.deepEqual(JSON.parse(request.options.body), { password: metricsPassword });
    assert.equal(passwordHash, "$2b$fixture-metrics-hash");
    assert.equal(editor.state.metricsPassword, "");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("new passwords match the server character, byte and NUL limits", async () => {
  const { validPassword } = await load("config/authusers.mjs");
  assert.equal(validPassword("12345678"), true);
  assert.equal(validPassword("1234567"), false);
  assert.equal(validPassword("😀😀"), false);
  assert.equal(validPassword("😀😀😀😀😀😀😀😀"), true);
  assert.equal(validPassword("😀".repeat(19)), false);
  assert.equal(validPassword("12345678\0"), false);
});

test("a completed hash cannot move to a different account", async () => {
  const { AuthUsersEditor } = await load("config/authusers.mjs");
  const originalFetch = globalThis.fetch;
  let finishHash;
  globalThis.fetch = async () => ({
    ok: true,
    json: () =>
      new Promise((resolve) => {
        finishHash = resolve;
      }),
  });
  try {
    const first = { name: "first", role: "admin", password_hash: { __secret__: true } };
    const second = { name: "second", role: "viewer", password_hash: { __secret__: true } };
    const editor = new AuthUsersEditor({ users: [first, second], onChange() {} });
    editor.setState = (next) => {
      editor.state = { ...editor.state, ...next };
    };
    editor.state.passwords = { 0: accountPassword };
    const pending = editor.resetPassword(0);
    await Promise.resolve();
    editor.props.users = [second];
    finishHash({ password_hash: "$2b$unused-hash" });
    await pending;
    assert.deepEqual(second.password_hash, { __secret__: true });
    assert.equal(editor.state.error, "Account changed while hashing; try again.");
  } finally {
    globalThis.fetch = originalFetch;
  }
});
