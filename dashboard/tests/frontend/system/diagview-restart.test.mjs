// Per-service restart in the Service diagnostics card (#4062): confirmation, closed request,
// in-progress and result states, and the browser list against the host's restart allowlist.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import {
  DIAG_RESTARTABLE,
  DiagnosticsPanel,
} from "../../../mining_dashboard/web/static/system/diagview.mjs";
import { renderToString } from "../helpers/render.mjs";

const ID = "22222222-2222-4222-8222-222222222222";
const okResult = (body) => ({ status: 200, ok: true, json: async () => body });

async function withFastPoll(fetchStub, fn) {
  const realFetch = globalThis.fetch;
  const realTimeout = globalThis.setTimeout;
  globalThis.fetch = fetchStub;
  globalThis.setTimeout = (cb) => {
    cb();
    return 0;
  };
  try {
    return await fn();
  } finally {
    globalThis.fetch = realFetch;
    globalThis.setTimeout = realTimeout;
  }
}

function inst(props = { enabled: true }, state = {}) {
  const panel = new DiagnosticsPanel(props);
  panel.props = props;
  panel.state = { ...panel.state, ...state };
  panel.setState = (next) => {
    const patch = typeof next === "function" ? next(panel.state, panel.props) : next;
    panel.state = { ...panel.state, ...patch };
  };
  return panel;
}

const restartPost = (opts) => JSON.parse(opts.body);

test("every restartable service shows a Restart button and the four platform services show none", () => {
  const out = renderToString(inst().render());
  assert.equal((out.match(/<button[^>]*>Restart [a-z0-9-]+/g) || []).length, DIAG_RESTARTABLE.length);
  for (const service of ["wallet-rpc", "tari-wallet", "tor", "monerod"]) {
    assert.match(out, new RegExp(`<button[^>]*>Restart ${service}\\b`));
  }
  for (const service of ["dashboard", "caddy", "docker-proxy", "docker-control"]) {
    assert.doesNotMatch(out, new RegExp(`<button[^>]*>Restart ${service}\\b`));
  }
});

test("the restart confirmation names the service and its dependents before anything is sent", () => {
  const panel = inst({ enabled: true }, { restarts: { tor: { phase: "confirm", result: null } } });
  const out = renderToString(panel.renderRestart("tor"));
  assert.match(out, /Restart tor\?/);
  assert.match(out, /monerod is restarted with it/);
  assert.match(out, /Confirm restart of tor/);
  assert.match(out, /Cancel/);
  const monerod = renderToString(
    inst({ enabled: true }, { restarts: { monerod: { phase: "confirm", result: null } } }).renderRestart("monerod"),
  );
  assert.match(monerod, /wallet-rpc is interrupted/);
});

test("a confirmed restart posts the closed request once, disables the button, and shows success", async () => {
  const posts = [];
  const fetchStub = async (url, opts) => {
    if (url === "/api/control/svc-restart") {
      posts.push({ headers: opts.headers, body: restartPost(opts) });
      return { status: 202, ok: false, json: async () => ({ id: ID }) };
    }
    return okResult({ status: "applied", container: "tor" });
  };
  const panel = inst();
  const run = withFastPoll(fetchStub, () => panel.runRestart("tor"));
  assert.equal(panel.state.restarts.tor.phase, "waiting");
  const waiting = renderToString(panel.renderRestart("tor"));
  assert.match(waiting, /disabled/);
  assert.match(waiting, /Waiting for the host to restart tor/);
  await run;
  assert.equal(panel.state.restarts.tor.phase, "done");
  assert.match(renderToString(panel.renderRestart("tor")), /tor was restarted/);
  assert.equal(posts.length, 1);
  assert.deepEqual(posts[0].body, { container: "tor" });
  assert.equal(posts[0].headers["X-Pithead-Control"], "1");
});

test("a host refusal or failure is shown verbatim as the restart result", async () => {
  for (const status of ["rejected", "failed"]) {
    const error = `host said no (${status})`;
    const fetchStub = async (url) =>
      url === "/api/control/svc-restart"
        ? { status: 202, ok: false, json: async () => ({ id: ID }) }
        : okResult({ status, error });
    const panel = inst();
    await withFastPoll(fetchStub, () => panel.runRestart("monerod"));
    assert.equal(panel.state.restarts.monerod.phase, "failed");
    assert.match(renderToString(panel.renderRestart("monerod")), new RegExp(error.replace(/[()]/g, "\\$&")));
  }
});

test("a transport failure on restart is a failed state, not an unhandled rejection", async () => {
  const panel = inst();
  await withFastPoll(
    async () => {
      throw new Error("offline");
    },
    () => panel.runRestart("p2pool"),
  );
  assert.equal(panel.state.restarts.p2pool.phase, "failed");
  assert.match(renderToString(panel.renderRestart("p2pool")), /Could not submit the p2pool restart/);
});

test("the browser restart list has not drifted from the host's restart allowlist", () => {
  const pithead = readFileSync(new URL("../../../../pithead", import.meta.url), "utf8");
  const match = /readonly PITHEAD_SVC_RESTART_SERVICES="([^"]*)"/.exec(pithead);
  assert.ok(match, "could not find PITHEAD_SVC_RESTART_SERVICES in pithead");
  assert.deepEqual([...DIAG_RESTARTABLE].sort(), match[1].split(/\s+/).filter(Boolean).sort());
});
