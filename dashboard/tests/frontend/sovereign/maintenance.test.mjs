import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { Maintenance, ServerHealth } from "../../../mining_dashboard/web/static/sovereign/maintenance.mjs";
import { Inspect } from "../../../mining_dashboard/web/static/sovereign/inspect.mjs";
import { renderToString } from "../helpers/render.mjs";

test("read-only and non-mining server health distinguish missing telemetry from zero", () => {
  const out = renderToString(html`<${ServerHealth} state=${{ system: { cpu: { percent: "0%" } } }} />`);
  assert.match(out, /0%/);
  assert.match(out, /Not reported/);
  assert.match(out, /server without a local miner can still be healthy/);
  const maintenance = renderToString(html`<${Maintenance} state=${{ control_enabled: false }} />`);
  assert.match(maintenance, /signed-in session/);
  assert.doesNotMatch(maintenance, /Show recent log|Reboot|Power off/);
});

test("inspection omits disabled Tari and keeps configuration separate from measurements", () => {
  const state = { tari: { active: false }, topology: { nodes: [{ id: "tari", label: "Tari node" }, { id: "monerod", label: "Monero", remote: true }], edges: [{ from: "monerod", to: "tari", route: "lan" }] }, network: { height: 0 } };
  const out = renderToString(html`<${Inspect} state=${state} />`);
  assert.doesNotMatch(out, /Tari node|Tari height|monerod → tari/);
  assert.match(out, /Configured paths are not observed traffic or proof of reachability/);
  assert.match(out, /Remote/);
  assert.match(out, /Network height/);
});

test("a support download cannot start before a review and a prepared report", async (t) => {
  const instance = new Maintenance({ state: { control_enabled: true } });
  const request = t.mock.method(globalThis, "fetch", async () => { throw new Error("unexpected request"); });
  await instance.download();
  instance.state.bundle = { id: "old-report" };
  await instance.download();
  assert.equal(request.mock.callCount(), 0);
});

function host(t, result) {
  const instance = new Maintenance({ state: { control_enabled: true } });
  instance.setState = (patch) => Object.assign(instance.state, patch);
  t.mock.method(globalThis, "setTimeout", (callback) => callback());
  t.mock.method(globalThis, "fetch", async (url) =>
    url.includes("/result?")
      ? Response.json(result, { status: result ? 200 : 202 })
      : Response.json({ id: "report-id" }, { status: 202 }),
  );
  return instance;
}

test("health reports retain timestamps and service, worker and machine checks", async (t) => {
  const doctor = {
    summary: { fail: 1, warn: 1, ok: 1 },
    checks: [
      { status: "fail", message: "monerod is not answering" },
      { status: "warn", message: "worker sample unavailable" },
      { status: "ok", message: "Disk is writable" },
    ],
  };
  const instance = host(t, { status: "applied", doctor, ts: 100 });
  await instance.run("health");
  const out = renderToString(instance.render(instance.props, instance.state));
  assert.match(out, /1 failing, 1 warning, 1 ok/);
  assert.match(out, /1970-01-01T00:01:40.000Z/);
  for (const text of ["monerod", "xmrig-proxy", "Machine checks", "Disk is writable"])
    assert.ok(out.includes(text));
  assert.equal(instance.state.waiting, null);
});

for (const result of [{ status: "failed", error: "Host refused" }, { status: "applied" }, { doctor: [] }]) {
  test(`unusable health results do not invent reports: ${JSON.stringify(result)}`, async (t) => {
    const instance = host(t, result);
    instance.state.report = { doctor: { checks: [{ status: "ok", message: "Old check" }] }, ts: 1 };
    await instance.run("health");
    assert.equal(instance.state.report, null);
    assert.match(instance.state.error, /Host refused|no report/);
  });
}

test("a queued or running request stays uncertain after the polling wait expires", async (t) => {
  const instance = host(t, null);
  instance.state.report = { doctor: { checks: [{ status: "ok", message: "Old check" }] }, ts: 1 };
  const pending = instance.run("health");
  assert.equal(instance.state.waiting, "health");
  assert.match(renderToString(instance.render(instance.props, instance.state)), /queued or running/);
  await pending;
  assert.match(instance.state.error, /may still be queued or running/);
  assert.equal(instance.state.report, null);
});

test("a new bundle clears the previous review and a failed collection cannot export old reports", async (t) => {
  const instance = host(t, { status: "failed", error: "No reports" });
  instance.state.bundle = { id: "old-report" };
  instance.state.reviewed = true;
  await instance.run("bundle");
  assert.equal(instance.state.bundle, null);
  assert.equal(instance.state.reviewed, false);
  assert.equal(instance.state.error, "No reports");
});

test("read-only and in-flight maintenance cannot submit or download", async (t) => {
  const instance = host(t, {});
  instance.props.state.control_enabled = false;
  instance.state.bundle = { id: "report" };
  instance.state.reviewed = true;
  await instance.run("bundle");
  await instance.download();
  instance.props.state.control_enabled = true;
  instance.state.waiting = "health";
  await instance.run("bundle");
  await instance.download();
  assert.equal(globalThis.fetch.mock.callCount(), 0);
});

test("server and network details consume the producer fixture and mark unavailable readings", () => {
  const state = JSON.parse(readFileSync(new URL("../fixtures/state.json", import.meta.url)));
  const out = renderToString(html`<${ServerHealth} state=${state} />`);
  assert.ok(out.includes(state.system.cpu.load));
  assert.ok(out.includes(`${state.system.disk.used} / ${state.system.disk.total} ${state.system.disk.unit}`));
  assert.match(out, /Swap<\/dt><dd>Not reported/);
  assert.match(out, /Server uptime<\/dt><dd>Not reported/);
  const inspect = renderToString(html`<${Inspect} state=${state} />`);
  for (const text of [state.monero.health.status, state.pool.peers, state.pool.pplns_win])
    assert.ok(inspect.includes(String(text)));
  assert.match(inspect, /RPC, ZMQ and gRPC reachability is not measured/);
  const missing = renderToString(html`<${Inspect} state=${{ sync: { monero: { percent: null } } }} />`);
  assert.doesNotMatch(missing, /null%|undefined%/);
  assert.match(missing, /Monero sync<\/dt><dd>Not reported/);
});

test("reported memory, disk and database problems stay visible without a fabricated health verdict", () => {
  for (const resource of ["mem", "disk"]) {
    const out = renderToString(html`<${ServerHealth} state=${{ system: { [resource]: { level: "high" } }, db_healthy: false }} />`);
    assert.match(out, /High memory or disk usage reported/);
    assert.match(out, /Database<\/dt><dd>Needs attention/);
    assert.doesNotMatch(out, /undefined|null|NaN/);
  }
});

test("unavailable browser storage keeps inspection usable and reports the default preference", (t) => {
  const saved = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  Object.defineProperty(globalThis, "localStorage", { configurable: true, get() { throw new Error("storage refused"); } });
  t.after(() => {
    if (saved) Object.defineProperty(globalThis, "localStorage", saved);
    else delete globalThis.localStorage;
  });
  const out = renderToString(html`<${Inspect} state=${{}} />`);
  assert.match(out, /Saved mesh preference is unavailable/);
  assert.match(out, /Using the default for this visit/);
  assert.match(out, /Node, network and pool statistics/);
});
