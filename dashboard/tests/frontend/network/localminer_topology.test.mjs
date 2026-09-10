import assert from "node:assert/strict";
import test from "node:test";

import { clone, renderApp } from "../harness.mjs";

test("the configured built-in miner is separate from external rigs (#1856)", () => {
  const state = clone();
  state.topology.nodes.push({ id: "local-miner", label: "Built-in miner", zone: "host" });
  state.topology.edges.push({
    from: "local-miner",
    to: "xmrig-proxy",
    route: "local",
    label: "local stratum",
    kind: "ingress",
  });
  const output = renderApp({ state });
  assert.match(output, /Built-in miner/);
  assert.match(output, /External rigs/);
});
