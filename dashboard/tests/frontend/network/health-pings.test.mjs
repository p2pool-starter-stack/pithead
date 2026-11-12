// #4037: the health page surfaces recent failed Healthchecks.io pings, with an empty state,
// and never renders the ping URL (it is a bearer credential — the recorder stores only a
// reason class and a status code; this checks the card does not invent a URL either).
import assert from "node:assert/strict";
import { test } from "node:test";

import { ComponentHealth } from "../../../mining_dashboard/web/static/network/health.mjs";
import { render } from "../helpers/render.mjs";

const topology = {
  summary: { level: "ok", label: "Tor-only egress", leaks: [] },
  nodes: [],
  edges: [],
};

test("no ping failures: a calm empty state and no failure list", () => {
  const out = render(ComponentHealth, { topology, egress: null, ping_failures: [] });
  assert.match(out, /Monitoring ping/);
  assert.match(out, /No failed pings recorded/);
  assert.doesNotMatch(out, /<ul class="ping-failures">/);
});

test("undefined ping_failures (older state payload) renders the empty state, not a crash", () => {
  const out = render(ComponentHealth, { topology });
  assert.match(out, /No failed pings recorded/);
});

test("failures render newest-first with the mapped reason label and detail", () => {
  const out = render(ComponentHealth, {
    topology,
    egress: null,
    ping_failures: [
      { ts: 1_762_900_000, reason: "http_status", detail: "HTTP 404" },
      { ts: 1_762_890_000, reason: "tor_socks", detail: "ProxyError" },
    ],
  });
  assert.match(out, /ping-summary c-warn/);
  assert.match(out, /2 recent failures/);
  assert.match(out, /HTTP status/);
  assert.match(out, /Tor proxy/);
  assert.match(out, /HTTP 404/);
});

test("an unmapped reason still renders verbatim rather than vanishing", () => {
  const out = render(ComponentHealth, {
    topology,
    egress: null,
    ping_failures: [{ ts: 1, reason: "future_class", detail: "" }],
  });
  assert.match(out, /future_class/);
  assert.match(out, /1 recent failure<\/span>/);
});
