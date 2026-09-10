// Service Diagnostics card (#913 doctor detail, #943 log tail).
//
// One health-check request runs the host's existing `doctor --json` once. The result is grouped
// here for reading; the host contract stays {status,message}, so a row's complete message is the
// check and its remedy rather than a guessed third field. Recent logs stay separate, per-service
// disclosures and are fetched only when the operator asks for one.
//
// The host remains the authority for both actions. It redacts the doctor document and every log
// tail before either crosses into this container, clamps log output, and refuses services outside
// its fixed allowlist. Preact interpolation is the final output-escaping boundary in the browser.

import { Component, html } from "../app/preact.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const DIAG_POLL_MS = 2000;
const DIAG_POLL_MAX = 40; // ~80s — a wait limit, not proof that the host runner is stuck.

export const DIAG_CONTAINERS = [
  "tor",
  "monerod",
  "tari",
  "p2pool",
  "xmrig-proxy",
  "dashboard",
  "docker-proxy",
  "docker-control",
  "caddy",
];
export const DIAG_SERVICES = [
  "tor",
  "monerod",
  "wallet-rpc",
  "tari",
  "tari-wallet",
  ...DIAG_CONTAINERS.slice(3),
];

// Doctor has no section/name field. These narrow tokens group its existing messages for display;
// one cross-service check may appear under more than one service, while unmatched checks remain
// visible under Machine checks. No check is dropped or rewritten.
const SERVICE_HINTS = {
  tor: [/\btor\b/i, /\bonion\b/i, /\bsocks\b/i, /egress firewall/i],
  monerod: [/\bmonerod\b/i, /\bmonero node\b/i, /monero.*synchron/i],
  "wallet-rpc": [/\bwallet-rpc\b/i, /\bwallet rpc\b/i, /\bmonero wallet\b/i],
  tari: [/\btari\b/i],
  "tari-wallet": [/\btari-wallet\b/i, /\btari wallet\b/i],
  p2pool: [/\bp2pool\b/i, /\bstratum\b/i, /\bsidechain\b/i],
  "xmrig-proxy": [/\bxmrig(?:-proxy)?\b/i, /\bworker(?:s)?\b/i],
  dashboard: [/\bdashboard\b/i],
  "docker-proxy": [/\bdocker-proxy\b/i],
  "docker-control": [
    /\bdocker-control\b/i,
    /\bcontrol channel\b/i,
    /\bcontrol runner\b/i,
    /\brunner units\b/i,
    /\bpithead-control\b/i,
  ],
  caddy: [/\bcaddy\b/i, /\bcertificate\b/i],
};

export class DiagnosticWaitTimeout extends Error {
  constructor(label) {
    super(
      `Stopped waiting for ${label}. The request may still be queued or running on the host; ` +
        "this wait limit does not show that the control runner is stuck. Reload, then run the check again only after the earlier request has finished.",
    );
    this.name = "DiagnosticWaitTimeout";
  }
}

// Diagnostics do not write an intermediate `running` result: HTTP 202 means only that no durable
// result exists yet. Keep that uncertainty instead of borrowing the upgrade flow's version copy or
// calling the runner wedged from elapsed time alone.
export async function runDiag(path, body, label = "the diagnostics request", max = DIAG_POLL_MAX) {
  let res;
  try {
    res = await fetch(`/api/control/${path}`, {
      method: "POST",
      headers: CONTROL_HEADERS,
      body: JSON.stringify(body || {}),
    });
  } catch {
    throw new Error(
      `Could not submit ${label}: the dashboard could not reach the control service.`,
    );
  }
  if (!res.ok && res.status !== 202)
    throw new Error(`Could not submit ${label}: HTTP ${res.status}`);
  let id;
  try {
    ({ id } = await res.json());
  } catch {
    throw new Error(`Could not submit ${label}: the host returned an unreadable response.`);
  }
  if (typeof id !== "string" || !id)
    throw new Error(`Could not submit ${label}: the host returned no request id.`);
  for (let i = 0; i < max; i++) {
    await new Promise((resolve) => setTimeout(resolve, DIAG_POLL_MS));
    let result;
    try {
      result = await fetch(`/api/control/result?id=${encodeURIComponent(id)}`);
    } catch {
      continue;
    }
    if (result.status === 202 || [502, 503, 504].includes(result.status)) continue;
    if (!result.ok) throw new Error(`Could not read ${label}: HTTP ${result.status}`);
    try {
      return await result.json();
    } catch {
      throw new Error(`Could not read ${label}: the host returned an unreadable result.`);
    }
  }
  throw new DiagnosticWaitTimeout(label);
}

export function doctorRows(doc) {
  const checks = doc && doc.checks;
  if (!Array.isArray(checks)) return [];
  const rank = (c) =>
    c.status === "fail" ? 0 : c.status === "warn" ? 1 : c.status === "info" ? 2 : 3;
  return checks
    .filter((c) => c && typeof c === "object")
    .map((c) => ({
      status: String(c.status ?? "").toLowerCase(),
      message: String(c.message ?? ""),
    }))
    .sort((a, b) => rank(a) - rank(b));
}

export function doctorSummary(doc) {
  const s = doc && doc.summary;
  if (!s || typeof s !== "object") return null;
  const n = (v) => (Number.isFinite(v) ? v : 0);
  return `${n(s.fail)} failing, ${n(s.warn)} warning, ${n(s.ok)} ok`;
}

const statusRank = (status) => ({ fail: 0, warn: 1, info: 2, ok: 3 })[status] ?? 4;

export function groupDoctorRows(doc) {
  const rows = doctorRows(doc);
  const services = DIAG_SERVICES.map((name) => ({ name, checks: [] }));
  const machine = [];
  for (const row of rows) {
    const matches = services.filter(({ name }) =>
      SERVICE_HINTS[name].some((hint) => hint.test(row.message)),
    );
    if (matches.length) {
      for (const service of matches) service.checks.push(row);
    } else {
      machine.push(row);
    }
  }
  for (const service of services) {
    service.status = service.checks.length
      ? service.checks.reduce(
          (worst, row) => (statusRank(row.status) < statusRank(worst) ? row.status : worst),
          service.checks[0].status,
        )
      : "not checked";
  }
  return { services, machine };
}

const STATUS_CLS = { fail: "status-bad", warn: "status-warn", ok: "status-ok" };

export class DiagnosticsPanel extends Component {
  constructor(props) {
    super(props);
    this.state = { healthPhase: "idle", healthResult: null, logs: {} };
  }

  async runHealth() {
    this.setState({ healthPhase: "waiting", healthResult: null });
    try {
      const result = await runDiag("diag-doctor", {}, "the health check");
      this.setState({
        healthPhase: result.status === "applied" ? "done" : "failed",
        healthResult: result,
      });
    } catch (error) {
      this.setState({
        healthPhase: "failed",
        healthResult: { error: String(error.message || error) },
      });
    }
  }

  async runLogs(container) {
    this.setState((state) => ({
      logs: { ...state.logs, [container]: { phase: "waiting", result: null } },
    }));
    try {
      const result = await runDiag(
        "diag-logs",
        { container, lines: 200 },
        `${container}'s recent log`,
      );
      this.setState((state) => ({
        logs: {
          ...state.logs,
          [container]: { phase: result.status === "applied" ? "done" : "failed", result },
        },
      }));
    } catch (error) {
      this.setState((state) => ({
        logs: {
          ...state.logs,
          [container]: { phase: "failed", result: { error: String(error.message || error) } },
        },
      }));
    }
  }

  renderChecks(rows) {
    if (!rows.length)
      return html`<p class="text-muted text-xs">No service-specific check returned.</p>`;
    return html`<div class="table-scroll"><table class="est-table">
      <tbody>
        ${rows.map(
          (row) => html`<tr>
            <td class=${STATUS_CLS[row.status] || "text-muted"}>${row.status || "—"}</td>
            <td>${row.message}</td>
          </tr>`,
        )}
      </tbody>
    </table></div>`;
  }

  renderLog(container) {
    if (!DIAG_CONTAINERS.includes(container)) {
      return html`<p class="text-muted text-xs">Its logs stay in the owner-only support bundle.</p>`;
    }
    const log = this.state.logs[container] || { phase: "idle", result: null };
    const busy = log.phase === "waiting";
    const result = log.result;
    return html`<details>
      <summary>Recent log</summary>
      <button class="btn-toggle" disabled=${busy} onClick=${() => this.runLogs(container)}>
        ${result ? "Refresh recent log" : "Show recent log"}
      </button>
      ${busy ? html`<p class="text-muted">Waiting for the host to return ${container}'s recent log…</p>` : null}
      ${
        log.phase === "failed"
          ? html`<p class="status-bad">${(result && (result.error || result.note)) || "The host failed to read this log."}</p>`
          : null
      }
      ${
        log.phase === "done"
          ? result.lines
            ? html`<pre class="config-error-tail font-mono text-xs">${result.lines}</pre>`
            : html`<p class="text-muted">${result.note || "No log output."}</p>`
          : null
      }
    </details>`;
  }

  renderService(service, haveReport) {
    return html`<section>
      <h4>${service.name}
        ${
          haveReport
            ? html`<span class=${STATUS_CLS[service.status] || "text-muted"}> — ${service.status}</span>`
            : null
        }
      </h4>
      ${
        haveReport
          ? this.renderChecks(service.checks)
          : html`<p class="text-muted text-xs">Run the health check to see this service's checks.</p>`
      }
      ${this.renderLog(service.name)}
    </section>`;
  }

  render() {
    if (!this.props.enabled) {
      return html`<div class="card">
        <h3>Service diagnostics</h3>
        <p>Diagnostics are off with the rest of the control channel. To enable them, set
        <code>dashboard.control.enabled: true</code> in <code>config.json</code> on the host
        and run <code>./pithead apply</code>. It requires a dashboard login.</p>
      </div>`;
    }
    const { healthPhase, healthResult } = this.state;
    const haveReport = healthPhase === "done" && healthResult && healthResult.doctor;
    const groups = groupDoctorRows(haveReport ? healthResult.doctor : null);
    const reportRows = haveReport ? doctorRows(healthResult.doctor) : [];
    const summary = haveReport ? doctorSummary(healthResult.doctor) : null;
    return html`<div class="card">
      <h3>Service diagnostics</h3>
      <p>Run the host's read-only health check once. Every service and the machine checks appear
      below; open a service's recent log only when you need it.</p>
      <button class="btn-toggle active" disabled=${healthPhase === "waiting"}
              onClick=${() => this.runHealth()}>Run health check</button>
      ${
        healthPhase === "waiting"
          ? html`<p class="text-muted">Waiting for the host to return the health check…</p>`
          : null
      }
      ${
        healthPhase === "failed"
          ? html`<p class="status-bad">${(healthResult && (healthResult.error || healthResult.note)) || "The host failed to run the health check."}</p>`
          : null
      }
      ${summary ? html`<p class="text-muted text-xs">${summary}</p>` : null}
      ${
        haveReport && !reportRows.length
          ? html`<p class="text-muted">The host returned a report with no checks in it.</p>`
          : null
      }
      ${groups.services.map((service) => this.renderService(service, haveReport))}
      ${
        haveReport
          ? html`<section>
          <h4>Machine checks</h4>
          ${
            reportRows.length && groups.machine.length
              ? this.renderChecks(groups.machine)
              : reportRows.length
                ? html`<p class="text-muted text-xs">Every returned check was service-specific.</p>`
                : html`<p class="text-muted text-xs">No machine check returned.</p>`
          }
        </section>`
          : null
      }
    </div>`;
  }
}
