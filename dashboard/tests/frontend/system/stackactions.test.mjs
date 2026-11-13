import assert from "node:assert/strict";
import { test } from "node:test";

import { DiagnosticsPanel } from "../../../mining_dashboard/web/static/system/diagview.mjs";
import {
  RESTART_ALL_POLL_MAX,
  RestartAllControl,
  TOR_RESET_POLL_MAX,
  TorResetControl,
  awaitRestartResult,
} from "../../../mining_dashboard/web/static/system/stackactions.mjs";
import { renderToString } from "../helpers/render.mjs";

const ID = "22222222-2222-4222-8222-222222222222";
const json = (status, body) => ({ status, ok: status < 300, json: async () => body });

async function withStubs(fetchStub, fn) {
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

function inst(Cls, props = {}, state = {}) {
  const c = new Cls(props);
  c.props = props;
  c.state = { ...c.state, ...state };
  c.setState = (next) => {
    const patch = typeof next === "function" ? next(c.state, c.props) : next;
    c.state = { ...c.state, ...patch };
  };
  return c;
}

const view = (c) => renderToString(c.render());

test("Restart all asks for the typed word and says what will happen", () => {
  const c = inst(RestartAllControl, {}, { phase: "confirming", text: "" });
  const out = view(c);
  assert.match(out, /Mining stops briefly/);
  assert.match(out, /goes offline/);
  assert.match(out, /not rebooted/);
  assert.match(out, /<button[^>]*disabled[^>]*>Restart the stack/);
  c.state.text = "RESTART";
  assert.doesNotMatch(view(c), /<button[^>]*disabled[^>]*>Restart the stack/);
  c.state.text = "restart";
  assert.match(view(c), /<button[^>]*disabled[^>]*>Restart the stack/);
});

test("awaitRestartResult rides out the offline window and returns the host result", async () => {
  const replies = [
    () => {
      throw new TypeError("offline");
    },
    () => json(502, {}),
    () => json(202, {}),
    () => json(200, { status: "applied" }),
  ];
  const seen = [];
  const result = await withStubs(
    () => replies.shift()(),
    () =>
      awaitRestartResult(ID, {
        onOffline: () => seen.push("offline"),
        onWaiting: () => seen.push("waiting"),
      }),
  );
  assert.deepEqual(result, { status: "applied" });
  assert.deepEqual(seen, ["offline", "offline", "waiting"]);
});

test("awaitRestartResult gives up at its named budget instead of polling forever", async () => {
  let calls = 0;
  const result = await withStubs(
    () => {
      calls += 1;
      throw new TypeError("offline");
    },
    () => awaitRestartResult(ID),
  );
  assert.equal(result, null);
  assert.equal(calls, RESTART_ALL_POLL_MAX);
  assert.ok(RESTART_ALL_POLL_MAX > 40);
});

test("Restart all submits the typed word, shows offline, then reloads on the applied result", async () => {
  let reloaded = 0;
  const c = inst(RestartAllControl, { reload: () => reloaded++ });
  const calls = [];
  const replies = [
    json(202, { id: ID, status: "pending" }),
    () => {
      throw new TypeError("offline");
    },
    json(200, { status: "applied" }),
  ];
  await withStubs(
    (url, init) => {
      calls.push([url, init && init.body]);
      const next = replies.shift();
      return typeof next === "function" ? next() : next;
    },
    () => c.restart(),
  );
  assert.deepEqual(calls[0], ["/api/control/restart", JSON.stringify({ confirm: "RESTART" })]);
  assert.equal(c.state.phase, "done");
  assert.equal(reloaded, 1);
});

test("Restart all shows the host's refusal verbatim and does not reload", async () => {
  let reloaded = 0;
  const c = inst(RestartAllControl, { reload: () => reloaded++ });
  const reason = "an OS update is in progress (installing) — try again later";
  const replies = [json(202, { id: ID }), json(200, { status: "rejected", error: reason })];
  await withStubs(() => replies.shift(), () => c.restart());
  assert.equal(c.state.phase, "failed");
  assert.equal(reloaded, 0);
  assert.ok(view(c).includes(reason));
});

test("Restart all prints a clear message when the stack has not returned", async () => {
  const c = inst(RestartAllControl, { reload: () => assert.fail("must not reload") });
  let first = true;
  await withStubs(
    () => {
      if (first) {
        first = false;
        return json(202, { id: ID });
      }
      throw new TypeError("offline");
    },
    () => c.restart(),
  );
  assert.equal(c.state.phase, "failed");
  assert.match(view(c), /has not answered within 10 minutes/);
});

test("Restart all reports a submit failure", async () => {
  const c = inst(RestartAllControl);
  await withStubs(() => json(403, {}), () => c.restart());
  assert.equal(c.state.phase, "failed");
  assert.match(view(c), /HTTP 403/);
});

test("Reset Tor state has its own confirmation naming what it discards and that it can refuse", () => {
  const c = inst(TorResetControl, { run: async () => ({}) }, { phase: "confirming" });
  const out = view(c);
  assert.match(out, /discards Tor's circuit history/);
  assert.match(out, /host can refuse/);
  assert.match(out, /Cancel/);
});

test("Reset Tor state runs the reset verb with a long wait and shows the result", async () => {
  const calls = [];
  const c = inst(TorResetControl, {
    run: async (...args) => {
      calls.push(args);
      return { status: "applied" };
    },
  });
  await c.reset();
  assert.deepEqual(calls, [["tor-reset", {}, "the Tor state reset", TOR_RESET_POLL_MAX]]);
  assert.equal(c.state.phase, "done");
  assert.match(view(c), /Tor state was reset/);
});

test("Reset Tor state shows a gate refusal verbatim and a thrown wait as a refusal", async () => {
  const reason = "[WARNING] Tor recovery refused: the persistent six-hour cooldown is active.";
  const c = inst(TorResetControl, { run: async () => ({ status: "failed", error: reason }) });
  await c.reset();
  assert.equal(c.state.phase, "refused");
  assert.ok(view(c).includes(reason));
  const d = inst(TorResetControl, {
    run: async () => {
      throw new Error("Stopped waiting for the Tor state reset.");
    },
  });
  await d.reset();
  assert.match(view(d), /Stopped waiting/);
});

test("Reset Tor state is disabled while it runs", () => {
  const c = inst(TorResetControl, { run: async () => ({}) }, { phase: "running" });
  assert.match(view(c), /<button[^>]*disabled[^>]*>Reset Tor state/);
});

test("the diagnostics card carries Restart all, and Reset Tor state only on the tor card", () => {
  const panel = inst(DiagnosticsPanel, { enabled: true });
  const out = renderToString(panel.render());
  assert.match(out, /Restart all/);
  assert.equal(out.match(/Reset Tor state/g).length, 1);
  const torSection = out.slice(out.indexOf(">tor<"), out.indexOf(">monerod<"));
  assert.match(torSection, /Reset Tor state/);
});

test("a disabled control channel shows neither button", () => {
  const out = renderToString(inst(DiagnosticsPanel, { enabled: false }).render());
  assert.doesNotMatch(out, /Restart all|Reset Tor state/);
});
