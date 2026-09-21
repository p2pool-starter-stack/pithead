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
          energy: { price_per_kwh: 0.1 },
        },
        monero: { mode: "local", remote: { host: "node.remote-monero-host.com", rpc_port: 18081 } },
        p2pool: { pool: "mini" },
        xvb: { enabled: false, url: "na.xmrvsbeast.com:4247" },
        _default_keys: ["monero.remote.host", "monero.remote.rpc_port", "xvb.url"],
        _editable_keys: ["dashboard.energy.price_per_kwh"],
      });
    }
    previewBody = JSON.parse(opts.body);
    return okResult({ status: "previewed", changes: [] });
  };
  try {
    await view.load();
    const field = view.state.sections
      .flatMap((section) => section.fields)
      .find(({ key }) => key === "dashboard.energy.price_per_kwh");
    view.onFieldEdit(field, "0.15");
    await view.save();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.deepEqual(previewBody.config, {
    dashboard: {
      auth: { password: { __secret__: true } },
      energy: { price_per_kwh: 0.15 },
    },
    monero: { mode: "local" },
    p2pool: { pool: "mini" },
    xvb: { enabled: false },
  });
});
