import assert from "node:assert/strict";
import { test } from "node:test";

import { ConfigView } from "../../../mining_dashboard/web/static/config/configview.mjs";

const okResult = (body) => ({ status: 200, ok: true, json: async () => body });

// #2365: the host receives the full explicit config, never untouched defaults from the reference.
test("save preserves explicit config and posts no untouched placeholder defaults", async () => {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  const realFetch = globalThis.fetch;
  let previewBody;
  globalThis.fetch = async (url, opts) => {
    if (url === "/api/config") {
      return okResult({
        dashboard: {
          auth: { password: { __secret__: true } },
          energy: { cost_per_kwh: 0.1 },
        },
        monero: { mode: "local", remote: { host: "node.remote-monero-host.com", rpc_port: 18081 } },
        p2pool: { pool: "mini" },
        xvb: { enabled: false, url: "na.xmrvsbeast.com:4247" },
        _default_keys: ["monero.remote.host", "monero.remote.rpc_port", "xvb.url"],
        _editable_keys: ["dashboard.energy.cost_per_kwh"],
      });
    }
    previewBody = JSON.parse(opts.body);
    return okResult({ status: "previewed", changes: [] });
  };
  try {
    await view.load();
    const field = view.state.sections
      .flatMap((section) => section.fields)
      .find(({ key }) => key === "dashboard.energy.cost_per_kwh");
    view.onFieldEdit(field, "0.15");
    await view.save();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.deepEqual(previewBody.config, {
    dashboard: {
      auth: { password: { __secret__: true } },
      energy: { cost_per_kwh: 0.15 },
    },
    monero: { mode: "local" },
    p2pool: { pool: "mini" },
    xvb: { enabled: false },
  });
});

for (const [text, path] of [
  ['{"monero":{},"monero":{}}', "monero"],
  ['{"dashboard":{"auth":{"password":"first","password":"last"}}}', "dashboard.auth.password"],
  ['{"workers":{"list":[{"token":"first","token":"last"}]}}', "workers.list[0].token"],
  ['{"monero":{},"\\u006donero":{}}', "monero"],
]) {
  test(`JSON editor refuses duplicate ${path} before Save can normalize it`, async () => {
    const view = new ConfigView({});
    view.setState = (patch) => Object.assign(view.state, patch);
    const original = { monero: { mode: "local" } };
    view.state.candidate = original;
    view.onJsonInput(text);
    assert.match(view.state.jsonError, /duplicate key/);
    assert.ok(view.state.jsonError.includes(path));
    assert.equal(view.state.candidate, original);
    const realFetch = globalThis.fetch;
    globalThis.fetch = async () => assert.fail("invalid JSON must never reach the preview spool");
    try {
      await view.save();
      assert.ok(view.state.error.includes(path));
    } finally {
      globalThis.fetch = realFetch;
    }
  });
}

test("a form placeholder refusal displays the backend path", async () => {
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  view.state.candidate = { dashboard: { auth: { password: "PASTE_secret" } } };
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: false, status: 400, text: async () => "placeholder value at dashboard.auth.password",
  });
  try {
    await view.save();
    assert.equal(view.state.phase, "form");
    assert.match(view.state.error, /placeholder value at dashboard.auth.password/);
    assert.doesNotMatch(view.state.error, /PASTE_secret/);
  } finally {
    globalThis.fetch = realFetch;
  }
});
