import assert from "node:assert/strict";
import { test } from "node:test";

import { explicitCandidate } from "../../../mining_dashboard/web/static/config/configlogic.mjs";

const pristine = {
  dashboard: {
    auth: { password: { __secret__: true } },
    energy: { cost_per_kwh: 0.1 },
  },
  monero: { mode: "local", remote: { host: "node.remote-monero-host.com", rpc_port: 18081 } },
  p2pool: { pool: "mini" },
  xvb: { enabled: false, url: "na.xmrvsbeast.com:4247" },
};
const defaults = ["monero.remote.host", "monero.remote.rpc_port", "xvb.url"];
const explicit = {
  dashboard: {
    auth: { password: { __secret__: true } },
    energy: { cost_per_kwh: 0.1 },
  },
  monero: { mode: "local" },
  p2pool: { pool: "mini" },
  xvb: { enabled: false },
};

test("untouched reference defaults stay out while explicit values and secrets survive", () => {
  assert.deepEqual(explicitCandidate(pristine, structuredClone(pristine), defaults), explicit);
});

test("one changed field is retained without materializing unrelated defaults", () => {
  const candidate = structuredClone(pristine);
  candidate.dashboard.energy.cost_per_kwh = 0.15;
  assert.deepEqual(explicitCandidate(pristine, candidate, defaults), {
    ...explicit,
    dashboard: {
      ...explicit.dashboard,
      energy: { cost_per_kwh: 0.15 },
    },
  });
});

test("editing a default makes it explicit", () => {
  const candidate = structuredClone(pristine);
  candidate.monero.remote.host = "node.example";
  assert.deepEqual(explicitCandidate(pristine, candidate, defaults).monero.remote, {
    host: "node.example",
  });
});

test("deleting an explicit leaf in the Advanced pane keeps it absent", () => {
  const candidate = structuredClone(pristine);
  delete candidate.p2pool.pool;
  const out = explicitCandidate(pristine, candidate, defaults);
  assert.equal(out.p2pool.pool, undefined);
  assert.deepEqual(out.monero, { mode: "local" });
});

test("one dashboard.energy save leaves untouched default arrays and empty containers out (#3355)", () => {
  const minimal = { dashboard: { energy: { cost_per_kwh: 0.1 } }, p2pool: { pool: "mini" } };
  // The served config is the reference merged under the host file, so it carries the default
  // arrays; the server lists them in _default_keys.
  const served = {
    ...structuredClone(minimal),
    workers: { api_port: 8080, list: [] },
    notifications: { webhooks: [], tor: true },
  };
  const arrayDefaults = [
    "workers.api_port",
    "workers.list",
    "notifications.webhooks",
    "notifications.tor",
  ];
  const candidate = structuredClone(served);
  candidate.dashboard.energy.cost_per_kwh = 0.15;
  assert.deepEqual(explicitCandidate(served, candidate, arrayDefaults), {
    dashboard: { energy: { cost_per_kwh: 0.15 } },
    p2pool: { pool: "mini" },
  });
});

test("an edited default array is kept as explicit (#3355)", () => {
  const served = { workers: { list: [] }, p2pool: { pool: "mini" } };
  const candidate = structuredClone(served);
  candidate.workers.list = [{ name: "rig" }];
  assert.deepEqual(explicitCandidate(served, candidate, ["workers.list"]).workers, {
    list: [{ name: "rig" }],
  });
});
