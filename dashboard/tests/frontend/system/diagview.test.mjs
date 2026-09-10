// Service Diagnostics card (#1961): one doctor request, all service/machine groups, on-demand
// per-service logs, and truthful wait/failure states from the diagnostics control contract.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import {
  DIAG_CONTAINERS,
  DIAG_SERVICES,
  DiagnosticsPanel,
  doctorRows,
  doctorSummary,
  groupDoctorRows,
  runDiag,
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

function vnodeFacts(root) {
  const tags = [];
  const text = [];
  const visit = (node) => {
    if (node == null || node === false) return;
    if (typeof node === "string" || typeof node === "number") {
      text.push(String(node));
      return;
    }
    if (Array.isArray(node)) {
      for (const child of node) visit(child);
      return;
    }
    if (typeof node === "object") {
      if (typeof node.type === "string") tags.push(node.type);
      visit(node.props && node.props.children);
    }
  };
  visit(root);
  return { tags, text };
}

const DOCTOR_DOC = {
  version: "2.0.0",
  exit: 2,
  summary: { ok: 3, warn: 1, fail: 2 },
  checks: [
    { status: "fail", message: "monerod is not answering — restart monerod." },
    { status: "warn", message: "Tor egress firewall is missing — run apply." },
    { status: "ok", message: "Dashboard answers through Caddy." },
    { status: "ok", message: "Free RAM: 8192 MiB available." },
    { status: "fail", message: "p2pool is down — inspect its recent log." },
    { status: "ok", message: "System clock is NTP-synchronized." },
  ],
};

test("doctor rows preserve the host's status/message contract and failure-first order", () => {
  const rows = doctorRows(DOCTOR_DOC);
  assert.deepEqual(rows.map((row) => row.status), ["fail", "fail", "warn", "ok", "ok", "ok"]);
  for (const row of rows) assert.deepEqual(Object.keys(row).sort(), ["message", "status"]);
  assert.deepEqual(
    rows.map((row) => row.message),
    [
      "monerod is not answering — restart monerod.",
      "p2pool is down — inspect its recent log.",
      "Tor egress firewall is missing — run apply.",
      "Dashboard answers through Caddy.",
      "Free RAM: 8192 MiB available.",
      "System clock is NTP-synchronized.",
    ],
  );
  assert.equal(doctorSummary(DOCTOR_DOC), "2 failing, 1 warning, 3 ok");
});

test("doctor rows tolerate another document shape without dropping valid siblings", () => {
  for (const doc of [null, {}, { checks: null }, { results: [] }]) assert.deepEqual(doctorRows(doc), []);
  assert.deepEqual(doctorRows({ checks: [null, "x", { status: "fail" }, { message: "m" }] }), [
    { status: "fail", message: "" },
    { status: "", message: "m" },
  ]);
});

test("one doctor document becomes every service plus remaining machine checks", () => {
  const grouped = groupDoctorRows(DOCTOR_DOC);
  assert.deepEqual(grouped.services.map(({ name }) => name), DIAG_SERVICES);
  assert.equal(grouped.services.find(({ name }) => name === "monerod").status, "fail");
  assert.equal(grouped.services.find(({ name }) => name === "tor").status, "warn");
  assert.equal(grouped.services.find(({ name }) => name === "p2pool").status, "fail");
  assert.equal(grouped.services.find(({ name }) => name === "tari").status, "not checked");
  assert.deepEqual(grouped.machine.map(({ message }) => message), [
    "Free RAM: 8192 MiB available.",
    "System clock is NTP-synchronized.",
  ]);
});

test("an empty doctor report remains explicit instead of claiming every check was grouped", () => {
  const out = renderToString(
    inst(
      { enabled: true },
      {
        healthPhase: "done",
        healthResult: {
          status: "applied",
          doctor: { summary: { ok: 0, warn: 0, fail: 0 }, checks: [] },
        },
      },
    ).render(),
  );
  assert.match(out, /host returned a report with no checks/);
  assert.match(out, /No machine check returned/);
  assert.doesNotMatch(out, /Every returned check was service-specific/);
});

test("a slow diagnostics request is submitted once and waits through pending to its result", async () => {
  let posts = 0;
  let polls = 0;
  const fetchStub = async (url, opts) => {
    if (url === "/api/control/diag-doctor") {
      posts++;
      assert.equal(opts.headers["X-Pithead-Control"], "1");
      return { status: 202, ok: false, json: async () => ({ id: ID }) };
    }
    polls++;
    if (polls === 1) return { status: 202, ok: false, json: async () => ({ status: "pending" }) };
    if (polls === 2) throw new TypeError("temporary disconnect");
    return okResult({ status: "applied", doctor: DOCTOR_DOC });
  };
  const panel = inst();
  await withFastPoll(fetchStub, () => panel.runHealth());
  assert.equal(posts, 1);
  assert.equal(panel.state.healthPhase, "done");
  assert.equal(panel.state.healthResult.doctor, DOCTOR_DOC);
});

test("a terminal host failure is a failed health check with the host's reason", async () => {
  const fetchStub = async (url) =>
    url === "/api/control/diag-doctor"
      ? { status: 202, ok: false, json: async () => ({ id: ID }) }
      : okResult({ status: "failed", error: "doctor did not return a readable report on this host." });
  const panel = inst();
  await withFastPoll(fetchStub, () => panel.runHealth());
  assert.equal(panel.state.healthPhase, "failed");
  assert.match(renderToString(panel.render()), /doctor did not return a readable report/);
});

test("a wait expiry keeps queued-vs-running unknown and does not invent a wedged runner", async () => {
  const fetchStub = async (url) =>
    url === "/api/control/diag-logs"
      ? { status: 202, ok: false, json: async () => ({ id: ID }) }
      : { status: 202, ok: false, json: async () => ({ status: "pending" }) };
  const panel = inst();
  await withFastPoll(fetchStub, () => panel.runLogs("tor"));
  const message = panel.state.logs.tor.result.error;
  assert.match(message, /tor's recent log/);
  assert.match(message, /may still be queued or running/);
  assert.match(message, /does not show that the control runner is stuck/);
  assert.doesNotMatch(message, /version|upgrade|slow connection|wedged/i);
});

test("submission and result HTTP failures name the diagnostics request", async () => {
  await assert.rejects(
    () => withFastPoll(async () => ({ status: 403, ok: false }), () => runDiag("diag-doctor", {}, "the health check")),
    /Could not submit the health check: HTTP 403/,
  );
  let first = true;
  await assert.rejects(
    () =>
      withFastPoll(
        async () => {
          if (first) {
            first = false;
            return { status: 202, ok: false, json: async () => ({ id: ID }) };
          }
          return { status: 500, ok: false };
        },
        () => runDiag("diag-logs", { container: "tor" }, "tor's recent log"),
      ),
    /Could not read tor's recent log: HTTP 500/,
  );
});

test("transport and malformed responses keep the diagnostics request context", async () => {
  await assert.rejects(
    () =>
      withFastPoll(
        async () => {
          throw new TypeError("Failed to fetch");
        },
        () => runDiag("diag-logs", { container: "tor" }, "tor's recent log"),
      ),
    /Could not submit tor's recent log: the dashboard could not reach the control service/,
  );

  await assert.rejects(
    () =>
      withFastPoll(
        async () => ({ status: 202, ok: false, json: async () => Promise.reject(new SyntaxError()) }),
        () => runDiag("diag-doctor", {}, "the health check"),
      ),
    /Could not submit the health check: the host returned an unreadable response/,
  );

  await assert.rejects(
    () =>
      withFastPoll(
        async (url) =>
          url === "/api/control/diag-doctor"
            ? { status: 202, ok: false, json: async () => ({ id: ID }) }
            : { status: 200, ok: true, json: async () => Promise.reject(new SyntaxError()) },
        () => runDiag("diag-doctor", {}, "the health check"),
      ),
    /Could not read the health check: the host returned an unreadable result/,
  );
});

test("the idle card shows all services and offers logs only where the host can redact them", () => {
  const out = renderToString(inst().render());
  assert.equal((out.match(/Run health check/g) || []).length, 1);
  assert.equal((out.match(/<summary>Recent log<\/summary>/g) || []).length, DIAG_CONTAINERS.length);
  assert.equal((out.match(/Show recent log/g) || []).length, DIAG_CONTAINERS.length);
  for (const service of DIAG_SERVICES) assert.match(out, new RegExp(`<h4>${service}`));
  assert.equal((out.match(/owner-only support bundle/g) || []).length, 2);
});

test("the health result renders service and machine failures with remedies, escaped", () => {
  const hostile = {
    ...DOCTOR_DOC,
    checks: [...DOCTOR_DOC.checks, { status: "fail", message: "<script>machine failed</script> — fix it." }],
  };
  const view = inst(
    { enabled: true },
    { healthPhase: "done", healthResult: { status: "applied", doctor: hostile } },
  ).render();
  const out = renderToString(view);
  const facts = vnodeFacts(view);
  assert.match(out, /monerod is not answering — restart monerod/);
  assert.match(out, /<h4>Machine checks<\/h4>/);
  assert.ok(facts.text.includes("<script>machine failed</script> — fix it."));
  assert.ok(!facts.tags.includes("script"));
});

test("a service log remains per-service, uses contextual waiting copy, and escapes output", () => {
  const waiting = renderToString(
    inst({ enabled: true }, { logs: { tor: { phase: "waiting", result: null } } }).render(),
  );
  assert.match(waiting, /Waiting for the host to return tor's recent log/);
  assert.doesNotMatch(waiting, /version|upgrade|slow connection/i);
  const done = inst(
    { enabled: true },
    { logs: { tor: { phase: "done", result: { status: "applied", lines: "<token>\nready" } } } },
  ).render();
  const facts = vnodeFacts(done);
  assert.ok(facts.text.includes("<token>\nready"));
  assert.ok(!facts.tags.includes("token"));
});

test("a terminal log refusal and an empty-log note keep the host's exact explanation", () => {
  const refused = renderToString(
    inst(
      { enabled: true },
      {
        logs: {
          tor: {
            phase: "failed",
            result: {
              status: "rejected",
              error: "not a service this dashboard may read logs for.",
            },
          },
        },
      },
    ).render(),
  );
  assert.match(refused, /not a service this dashboard may read logs for\./);

  const empty = renderToString(
    inst(
      { enabled: true },
      {
        logs: {
          tor: {
            phase: "done",
            result: { status: "applied", lines: "", note: "No log output — tor is not running." },
          },
        },
      },
    ).render(),
  );
  assert.match(empty, /No log output — tor is not running\./);
});

test("two service log disclosures keep both results", async () => {
  const fetchStub = async (url, opts) => {
    if (url === "/api/control/diag-logs") {
      const { container } = JSON.parse(opts.body);
      return {
        status: 202,
        ok: false,
        json: async () => ({ id: container === "tor" ? ID : ID.replace(/2/g, "3") }),
      };
    }
    const container = url.includes(ID) ? "tor" : "monerod";
    return okResult({ status: "applied", container, lines: `${container} ready` });
  };
  const panel = inst();
  await withFastPoll(fetchStub, () => Promise.all([panel.runLogs("tor"), panel.runLogs("monerod")]));
  assert.equal(panel.state.logs.tor.result.lines, "tor ready");
  assert.equal(panel.state.logs.monerod.result.lines, "monerod ready");
});

test("the card explains how to enable diagnostics when the control channel is off", () => {
  const out = renderToString(inst({ enabled: false }).render());
  assert.match(out, /dashboard\.control\.enabled/);
  assert.doesNotMatch(out, /Run health check/);
});

test("the browser service list has not drifted from the host's allowlist", () => {
  const pithead = readFileSync(new URL("../../../../pithead", import.meta.url), "utf8");
  const match = /readonly PITHEAD_DIAG_CONTAINERS="([^"]*)"/.exec(pithead);
  assert.ok(match, "could not find PITHEAD_DIAG_CONTAINERS in pithead");
  const hostList = match[1].split(/\s+/).filter(Boolean);
  assert.ok(hostList.length > 0, "the host diagnostics allowlist parsed as empty");
  assert.deepEqual([...DIAG_CONTAINERS].sort(), hostList.sort());
  assert.ok(DIAG_SERVICES.includes("wallet-rpc"));
  assert.ok(DIAG_SERVICES.includes("tari-wallet"));
  assert.ok(!DIAG_CONTAINERS.includes("wallet-rpc"));
  assert.ok(!DIAG_CONTAINERS.includes("tari-wallet"));
});
