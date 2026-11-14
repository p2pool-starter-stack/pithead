import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  LAN_SERVICES,
  LanAccessPanel,
  LanGuardStatus,
  SettingsPage,
  lanGuardVerdict,
  lanHost,
} from "../../../mining_dashboard/web/static/sovereign/settings.mjs";
import { renderToString } from "../helpers/render.mjs";

const baseConfig = () => ({
  monero: { rpc_lan_access: false, zmq_lan_access: false },
  tari: { grpc_lan_access: false },
});
const allKeys = LAN_SERVICES.map(({ key }) => key);
const host = { primary: "pithead.local", alt: "192.168.1.20" };

function panel(props = {}) {
  const component = new LanAccessPanel({
    enabled: true,
    host,
    onApplied: () => {},
    ...props,
  });
  component.setState = (update) => Object.assign(component.state, update);
  return component;
}

function loaded(component, { confirmKeys = allKeys, cfg = baseConfig() } = {}) {
  const text = JSON.stringify(cfg, null, 2);
  Object.assign(component.state, {
    phase: "form",
    cfg,
    candidate: JSON.parse(text),
    pristine: text,
    editText: text,
    confirmKeys,
    editableKeys: [],
    approvalKeys: [],
    defaultKeys: [],
  });
  return component;
}

function requests(fetcher, run) {
  const original = { fetch: globalThis.fetch, setTimeout: globalThis.setTimeout };
  globalThis.fetch = fetcher;
  globalThis.setTimeout = (fn) => {
    fn();
    return 0;
  };
  return run().finally(() => Object.assign(globalThis, original));
}

const response = (status, body) => ({
  status,
  ok: status >= 200 && status < 300,
  text: async () => (body === undefined ? "" : JSON.stringify(body)),
  json: async () => body,
});

test("the panel offers one named switch per service with its purpose", () => {
  const out = renderToString(loaded(panel()).render());
  for (const { service, note } of LAN_SERVICES) {
    assert.match(out, new RegExp(service));
    assert.match(out, new RegExp(note.slice(0, 40)));
  }
  assert.doesNotMatch(out, /lan-address/);
  assert.doesNotMatch(out, /Review and apply/);
});

test("a switched-on service shows the address with its published port, IP and connect note", () => {
  const cfg = baseConfig();
  cfg.monero.rpc_lan_access = true;
  const out = renderToString(loaded(panel(), { cfg }).render());
  assert.match(out, /<code>pithead\.local:18081<\/code>/);
  assert.match(out, /<code>192\.168\.1\.20:18081<\/code>/);
  assert.match(out, /Copy/);
  assert.match(out, /remote node/);
  assert.doesNotMatch(out, /18083/);
});

test("the shown ports are the ports compose publishes", () => {
  const compose = readFileSync(new URL("../../../../docker-compose.yml", import.meta.url), "utf8");
  const published = (bind) => {
    const found = compose.match(new RegExp(`"\\$\\{${bind}:-127\\.0\\.0\\.1\\}:(\\d+):\\1"`));
    assert.ok(found, `${bind} is not published loopback-pinned in docker-compose.yml`);
    return Number(found[1]);
  };
  assert.deepEqual(
    Object.fromEntries(LAN_SERVICES.map(({ key, port }) => [key, port])),
    {
      "monero.rpc_lan_access": published("MONERO_RPC_BIND"),
      "monero.zmq_lan_access": published("MONERO_ZMQ_BIND"),
      "tari.grpc_lan_access": published("TARI_GRPC_BIND"),
    },
  );
});

test("an undetected host still names the port; a missing host shows no address", () => {
  assert.deepEqual(lanHost({ host_ip: "Unknown Host", host_addr: "10.0.0.9" }), {
    primary: "10.0.0.9",
    alt: null,
  });
  assert.equal(lanHost({ host_ip: "Unknown Host" }), null);
  const cfg = baseConfig();
  cfg.tari.grpc_lan_access = true;
  const out = renderToString(loaded(panel({ host: null }), { cfg }).render());
  assert.match(out, /Address not detected[\s\S]*<code>18142<\/code>/);
});

test("flipping a switch back reverts the candidate and hides apply", () => {
  const component = loaded(panel());
  component.onFieldEdit({ key: "monero.rpc_lan_access", type: "boolean" }, true);
  assert.match(renderToString(component.render()), /Review and apply changes/);
  component.onFieldEdit({ key: "monero.rpc_lan_access", type: "boolean" }, false);
  assert.equal(component.state.editText, component.state.pristine);
  assert.doesNotMatch(renderToString(component.render()), /Review and apply changes/);
});

test("apply previews the toggled key through the existing control path and commits once", async () => {
  const applied = [];
  const component = loaded(panel({ onApplied: () => applied.push("checked") }));
  component.onFieldEdit({ key: "tari.grpc_lan_access", type: "boolean" }, true);
  await requests(async (url, options) => {
    if (url === "/api/control/preview") {
      assert.equal(options.headers["X-Pithead-Control"], "1");
      assert.equal(JSON.parse(options.body).config.tari.grpc_lan_access, true);
      return response(200, { id: "r1", status: "previewed", changes: [{ msg: "tari.grpc_lan_access" }] });
    }
    if (url === "/api/control/commit") {
      assert.deepEqual(JSON.parse(options.body), { id: "r1" });
      return response(200, { id: "r1", status: "applied" });
    }
    throw new Error(`unexpected request ${url}`);
  }, async () => {
    await component.save();
    assert.equal(component.state.phase, "confirm");
    await component.commit();
    assert.equal(component.state.phase, "done");
  });
  assert.equal(applied.length, 1);
  const done = renderToString(component.render());
  assert.match(done, /LAN rule check/);
  assert.match(done, /disabled/);
  assert.match(done, /Back to the switches/);
});

test("leaving the page clears the unsaved-changes flag", () => {
  const flags = [];
  loaded(panel({ onDirtyChange: (dirty) => flags.push(dirty) })).componentWillUnmount();
  assert.deepEqual(flags, [false]);
});

test("a not-yet-previewed commit is polled under the same id", async () => {
  const component = loaded(panel());
  Object.assign(component.state, {
    phase: "confirm",
    preview: { id: "r9", changes: [{ msg: "monero.zmq_lan_access" }] },
  });
  await requests(async (url) => {
    if (url === "/api/control/commit") return response(202, { id: "r9", status: "pending" });
    assert.equal(url, "/api/control/result?id=r9");
    return response(200, { id: "r9", status: "applied" });
  }, () => component.commit());
  assert.equal(component.state.phase, "done");
});

test("keys the host does not list leave the switches disabled", () => {
  const out = renderToString(loaded(panel(), { confirmKeys: [] }).render());
  assert.match(out, /disabled/);
  assert.match(out, /does not permit/);
});

test("a rejected preview stays on the form with the host reason", async () => {
  const component = loaded(panel());
  component.onFieldEdit({ key: "tari.grpc_lan_access", type: "boolean" }, true);
  await requests(
    () => response(200, { id: "r2", status: "rejected", error: "the host runner is busy" }),
    () => component.save(),
  );
  assert.equal(component.state.phase, "form");
  assert.match(renderToString(component.render()), /host runner is busy/);
});

test("the guard check reads the doctor lan-guard rows and the worst wins", () => {
  for (const [doctor, status] of [
    [{ checks: [{ id: "lan-guard", status: "ok", message: "live" }] }, "ok"],
    [
      {
        checks: [
          { id: "lan-guard", status: "ok", message: "live" },
          { id: "lan-guard-hold", status: "fail", message: "held" },
        ],
      },
      "fail",
    ],
    [{ checks: [{ id: "tor", status: "ok", message: "other" }] }, "unreported"],
  ])
    assert.equal(lanGuardVerdict(doctor).status, status);
});

test("the LAN rule starts unchecked and a failed rule is an alert", async () => {
  const status = new LanGuardStatus({});
  status.setState = (update) => Object.assign(status.state, update);
  assert.match(renderToString(status.render()), /Not checked yet/);
  await requests(
    async (url) =>
      url === "/api/control/diag-doctor"
        ? response(202, { id: "d1" })
        : response(200, {
            status: "applied",
            doctor: { checks: [{ id: "lan-guard", status: "fail", message: "rule is missing" }] },
          }),
    () => status.check(),
  );
  const out = renderToString(status.render());
  assert.match(out, /rule is missing/);
  assert.match(out, /role="alert"/);
});

test("the settings page renders the LAN access group only on a controllable session", () => {
  const writable = renderToString(
    new SettingsPage({ state: { control_enabled: true, host_ip: "pithead.local" } }).render(),
  );
  assert.match(writable, /<h2 id="lan-access-title">LAN access<\/h2>/);
  assert.match(writable, /Reading the host's current switches/);
  assert.match(writable, /LAN rule/);
  for (const state of [{ control_enabled: false }, null]) {
    const out = renderToString(new SettingsPage({ state }).render());
    assert.match(out, /Sign in with an active session/);
    assert.doesNotMatch(out, /Reading the host's current switches/);
  }
  assert.match(
    renderToString(
      new SettingsPage({ state: { control_enabled: true }, sessionExpired: true }).render(),
    ),
    /Sign in with an active session/,
  );
});
