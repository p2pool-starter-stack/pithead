import assert from "node:assert/strict";
import { test } from "node:test";

import { diffConfig } from "../../../mining_dashboard/web/static/config/configlogic.mjs";

// #2365: the loaded config carries config.reference.json's placeholder defaults for every unset
// key. One changed field must yield one key; an untouched placeholder must never reach the payload.
test("one changed field yields one key; untouched reference defaults stay out", () => {
  const base = {
    dashboard: { energy: { price_per_kwh: 0.1 } },
    monero: { mode: "local", remote: { host: "node.remote-monero-host.com", rpc_port: 18081 } },
    xvb: { enabled: false, url: "na.xmrvsbeast.com:4247" },
  };
  const candidate = structuredClone(base);
  candidate.dashboard.energy.price_per_kwh = 0.15;
  assert.deepEqual(diffConfig(base, candidate), { dashboard: { energy: { price_per_kwh: 0.15 } } });
});

test("no edits yields an empty payload", () => {
  const base = { monero: { mode: "local" }, xvb: { url: "na.xmrvsbeast.com:4247" } };
  assert.deepEqual(diffConfig(base, structuredClone(base)), {});
});

test("an untouched secret sentinel is not treated as a change", () => {
  const base = { dashboard: { auth: { password: { __secret__: true } } } };
  assert.deepEqual(diffConfig(base, structuredClone(base)), {});
});

test("a newly typed secret overrides its sentinel", () => {
  const base = { dashboard: { auth: { password: { __secret__: true } } } };
  const candidate = { dashboard: { auth: { password: "new-pass" } } };
  assert.deepEqual(diffConfig(base, candidate), { dashboard: { auth: { password: "new-pass" } } });
});
