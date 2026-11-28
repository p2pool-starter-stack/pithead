import assert from "node:assert/strict";
import { test } from "node:test";

import { clone, renderApp } from "../harness.mjs";

const ALERT = {
  title: "Monero node offline",
  reasons: ["0 outgoing peers for 12 min"],
  heal: ["Tor auto-heal stopped after 3 attempts; no more automatic action this outage."],
};

test("no node alert renders no banner", () => {
  assert.equal(renderApp({ state: clone() }).includes('id="node-alert"'), false);
});

test("a node alert names the outage, its reasons and the auto-heal state", () => {
  const state = clone();
  state.node_alert = ALERT;
  const html = renderApp({ state });
  assert.match(html, /id="node-alert"/);
  assert.match(html, /Monero node offline/);
  assert.match(html, /0 outgoing peers for 12 min/);
  assert.match(html, /Tor auto-heal stopped after 3 attempts/);
});
