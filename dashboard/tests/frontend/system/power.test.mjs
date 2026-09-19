// Plain power control (#2384): the typed-confirm gates, the POST contract, and the render gate.
// The host makes every real judgment (46b-control-power.sh) — these tests only check the client
// sequences the asks and renders the answers, and — the one behaviour specific to this control —
// that poweroff does NOT start the reconnect poll osupdate.mjs's reboot relies on.
//
// Run with Node's built-in test runner:
//     node --test dashboard/tests/frontend/*.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { powerAction, PowerControl } from "../../../mining_dashboard/web/static/system/power.mjs";
import { renderToString } from "../helpers/render.mjs";

const ID = "33333333-3333-4333-8333-333333333333";
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

function inst(props) {
  const c = new PowerControl(props);
  c.props = props;
  return c;
}

test("powerAction posts the typed action with the CSRF header and returns the id", async () => {
  let posted = null;
  await withFastPoll(
    async (url, opts) => {
      posted = { url, opts };
      return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
    },
    async () => {
      assert.equal(await powerAction("reboot"), ID);
    },
  );
  assert.equal(posted.url, "/api/control/power");
  assert.equal(posted.opts.headers["X-Pithead-Control"], "1");
  assert.deepEqual(JSON.parse(posted.opts.body), { action: "reboot" });
});

test("PowerControl renders nothing when the control channel is off", () => {
  assert.equal(renderToString(inst({ enabled: false }).render()), "");
});

test("PowerControl renders the Power badge when enabled", () => {
  const out = renderToString(inst({ enabled: true }).render());
  assert.match(out, /Power/);
});

test("the reboot confirm requires the typed REBOOT before it enables", () => {
  const c = inst({ enabled: true });
  c.state.phase = "confirm-reboot";
  c.state.confirmText = "";
  assert.match(renderToString(c.render()), /disabled[^>]*>\s*Reboot now/);
  c.state.confirmText = "REBOOT";
  assert.doesNotMatch(renderToString(c.render()), /disabled.*Reboot now/);
});

test("the poweroff confirm requires the typed POWEROFF and warns it will not come back on its own", () => {
  const c = inst({ enabled: true });
  c.state.phase = "confirm-poweroff";
  c.state.confirmText = "";
  const out = renderToString(c.render());
  assert.match(out, /disabled[^>]*>\s*Power off now/);
  assert.match(out, /not.*come back on its own/);
  c.state.confirmText = "POWEROFF";
  assert.doesNotMatch(renderToString(c.render()), /disabled.*Power off now/);
});

test("reboot() reconnects when the host accepts the order", async () => {
  const c = inst({ enabled: true });
  let reconnectCalled = false;
  c.reconnect = () => {
    reconnectCalled = true;
  };
  await withFastPoll(
    async (url, opts) => {
      if (opts && opts.method === "POST") {
        return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
      }
      return okResult({ status: "rebooting" });
    },
    () => c.reboot(),
  );
  assert.equal(reconnectCalled, true);
});

test("reboot() surfaces a host refusal instead of reconnecting", async () => {
  const c = inst({ enabled: true });
  let reconnectCalled = false;
  let failedWith = null;
  c.reconnect = () => {
    reconnectCalled = true;
  };
  c.fail = (e) => {
    failedWith = String((e && e.message) || e);
  };
  await withFastPoll(
    async (url, opts) => {
      if (opts && opts.method === "POST") {
        return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
      }
      return okResult({ status: "rejected", error: "another power request is already running" });
    },
    () => c.reboot(),
  );
  assert.equal(reconnectCalled, false);
  assert.match(failedWith, /already running/);
});

test("poweroff() does NOT start the reconnect poll — the machine is not coming back on its own", async () => {
  // setState on an unmounted component lands in _nextState, not this.state (same caveat
  // osupdate.test.mjs works around), so the final phase is read off the last setState call
  // rather than off the instance.
  const c = inst({ enabled: true });
  let reconnectCalled = false;
  let lastPhase = null;
  c.reconnect = () => {
    reconnectCalled = true;
  };
  const realSetState = c.setState.bind(c);
  c.setState = (patch) => {
    if (patch.phase) lastPhase = patch.phase;
    realSetState(patch);
  };
  await withFastPoll(
    async (url, opts) => {
      if (opts && opts.method === "POST") {
        return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
      }
      return okResult({ status: "shutting-down" });
    },
    () => c.poweroff(),
  );
  assert.equal(reconnectCalled, false);
  assert.equal(lastPhase, "powered-off");
  c.state.phase = "powered-off"; // render() next reads plain this.state, not preact's _nextState
  const out = renderToString(c.render());
  assert.match(out, /physical power button/);
});

test("poweroff() surfaces a host refusal", async () => {
  const c = inst({ enabled: true });
  let failedWith = null;
  c.fail = (e) => {
    failedWith = String((e && e.message) || e);
  };
  await withFastPoll(
    async (url, opts) => {
      if (opts && opts.method === "POST") {
        return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
      }
      return okResult({ status: "rejected", error: "power control applies only to an appliance" });
    },
    () => c.poweroff(),
  );
  assert.match(failedWith, /appliance/);
});
