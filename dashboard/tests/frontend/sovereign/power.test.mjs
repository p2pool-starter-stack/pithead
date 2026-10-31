import assert from "node:assert/strict";
import { test } from "node:test";
import { PowerControl, powerAction } from "../../../mining_dashboard/web/static/sovereign/power.mjs";
import { renderToString } from "../helpers/render.mjs";

const snapshot = { os_update: {}, control_enabled: true };
function control() {
  const component = new PowerControl({ snapshot });
  component.setState = (update) => Object.assign(component.state, update);
  return component;
}
async function requests(fetcher, run) {
  const original = { fetch: globalThis.fetch, setTimeout: globalThis.setTimeout };
  globalThis.fetch = fetcher;
  globalThis.setTimeout = (fn) => { fn(); return 0; };
  try { await run(); } finally { Object.assign(globalThis, original); }
}
const response = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });

test("power controls appear only on a controllable appliance", () => {
  const component = control();
  for (const state of [null, {}, { control_enabled: true }, { os_update: {}, control_enabled: false }]) {
    assert.equal(renderToString(component.render({ snapshot: state })), "");
  }
  const out = renderToString(component.render({ snapshot }));
  assert.match(out, />Reboot</);
  assert.match(out, />Power off</);
});

test("both actions require their exact typed confirmation", async () => {
  for (const action of ["reboot", "poweroff"]) {
    const component = control();
    component.state = { action, phase: "confirm", confirmation: action };
    assert.match(renderToString(component.render({ snapshot })), /disabled/);
    await requests(() => { throw new Error("must not submit"); }, () => component.order());
    assert.equal(component.state.phase, "confirm");
    component.state.confirmation = action.toUpperCase();
    assert.doesNotMatch(renderToString(component.render({ snapshot })), /disabled/);
    if (action === "poweroff") assert.match(renderToString(component.render({ snapshot })), /physical power button/);
  }
});

test("a power request carries the action and control header", async () => {
  await requests(async (url, options) => {
    assert.equal(url, "/api/control/power");
    assert.equal(options.headers["X-Pithead-Control"], "1");
    assert.deepEqual(JSON.parse(options.body), { action: "reboot" });
    return response(202, { id: "receipt" });
  }, async () => assert.equal(await powerAction("reboot"), "receipt"));
});

test("submission failure and host refusal stay visible without reconnecting", async () => {
  for (const action of ["reboot", "poweroff"]) for (const refused of [false, true]) {
    const component = control();
    component.state = { action, confirmation: action.toUpperCase(), phase: "confirm" };
    component.reconnect = () => assert.fail("refused requests must not reconnect");
    await requests(async (_url, options) => options?.method === "POST"
      ? response(refused ? 202 : 500, { id: "receipt" })
      : response(200, { status: "rejected", error: "cooldown" }), () => component.order());
    assert.equal(component.state.phase, "error");
  }
});

test("accepted reboot reconnects; accepted poweroff never does", async () => {
  for (const action of ["reboot", "poweroff"]) {
    const component = control();
    let reconnected = false;
    component.state = { action, confirmation: action.toUpperCase(), phase: "confirm" };
    component.reconnect = async () => { reconnected = true; };
    await requests(async (_url, options) => options?.method === "POST"
      ? response(202, { id: "receipt" })
      : response(200, { status: action === "reboot" ? "rebooting" : "shutting-down" }), () => component.order());
    assert.equal(reconnected, action === "reboot");
    if (action === "poweroff") assert.match(renderToString(component.render({ snapshot })), /will not reconnect/);
  }
});
