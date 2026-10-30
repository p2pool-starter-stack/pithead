import { Component, html } from "../app/preact.mjs";
import { doctorSummary, groupDoctorRows, runDiag } from "../system/diagview.mjs";

export class Maintenance extends Component {
  constructor(props) {
    super(props);
    this.state = { waiting: null, error: "", report: null, bundle: null, reviewed: false };
  }
  async run(kind) {
    if (!this.props.state?.control_enabled || this.state.waiting) return;
    this.setState({
      waiting: kind,
      error: "",
      reviewed: false,
      ...(kind === "bundle" ? { bundle: null } : { report: null }),
    });
    try {
      const result = await runDiag(
        kind === "health" ? "diag-doctor" : "diag-bundle",
        {},
        kind === "health" ? "the health check" : "the browser bundle",
      );
      if (
        kind === "health" &&
        result.doctor &&
        typeof result.doctor === "object" &&
        !Array.isArray(result.doctor)
      )
        this.setState({ report: { doctor: result.doctor, ts: result.ts } });
      else if (kind === "bundle" && result.status === "applied" && result.kind === "diag-bundle")
        this.setState({ bundle: result });
      else throw new Error(result.error || "The host returned no report.");
    } catch (error) {
      this.setState({ error: error.message });
    } finally {
      this.setState({ waiting: null });
    }
  }
  async download() {
    if (
      !this.props.state?.control_enabled ||
      !this.state.reviewed ||
      !this.state.bundle ||
      this.state.waiting
    )
      return;
    this.setState({ waiting: "download", error: "" });
    try {
      const response = await fetch("/api/control/bundle-download", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Pithead-Control": "1" },
        body: JSON.stringify({ id: this.state.bundle.id, reviewed: true }),
      });
      if (!response.ok)
        throw new Error(`Could not download the reviewed bundle: HTTP ${response.status}.`);
      const url = URL.createObjectURL(await response.blob());
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = "pithead-browser-support.tar.gz";
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
    } catch (error) {
      this.setState({ error: error.message });
    } finally {
      this.setState({ waiting: null });
    }
  }
  render({ state }, { waiting, error, report, bundle, reviewed }) {
    const enabled = !!state?.control_enabled;
    const groups = report ? groupDoctorRows(report.doctor) : null;
    return html`<div>
      <p>Read-only checks and a browser-safe support bundle. Neither restarts services.</p>
      ${!enabled ? html`<p class="notice">Diagnostics require the settings editor and a signed-in session. On a read-only DIY host, use the CLI diagnostics.</p>` : null}
      <button type="button" disabled=${!enabled || !!waiting} onClick=${() => this.run("health")}>Run health check</button>${" "}
      <button type="button" disabled=${!enabled || !!waiting} onClick=${() => this.run("bundle")}>Prepare support bundle</button>
      ${waiting ? html`<p role="status">${waiting === "download" ? "Preparing the download…" : "Waiting for the host — the request may be queued or running."}</p>` : null}
      ${error ? html`<p role="alert">${error}</p>` : null}
      ${!report ? html`<p>No health report yet. Run a health check to collect one.</p>` : null}
      ${
        report
          ? html`<section class="panel" aria-label="Health report">
        <h4>Health report</h4><p>${doctorSummary(report.doctor) || "Summary not reported"}</p>
        <p>Report time: ${Number.isFinite(report.ts) ? new Date(report.ts * 1000).toISOString() : "not reported"}</p>
        ${[...groups.services.filter((group) => group.checks.length), { name: "Machine checks", checks: groups.machine }].filter((group) => group.checks.length).map((group) => html`<details><summary>${group.name}</summary><ul>${group.checks.map((row) => html`<li><strong>${row.status || "unknown"}</strong> — ${row.message}</li>`)}</ul></details>`)}
        ${!groups.services.some((group) => group.checks.length) && !groups.machine.length ? html`<p>No checks were reported.</p>` : null}
      </section>`
          : null
      }
      ${
        bundle
          ? html`<section class="panel" aria-label="Review support bundle">
        <h4>Review identifiers before download</h4>
        <p>This bundle contains the redacted doctor report and up to 200 lines per allowed service. Wallet-service logs and the full CLI archive are excluded. Redaction cannot recognize every identifier; review all reports before downloading or sharing.</p>
        <details><summary>Review collected reports</summary><pre class="review">${JSON.stringify(bundle.bundle, null, 2)}</pre></details>
        <label class="review-label"><input type="checkbox" checked=${reviewed} onChange=${(event) => this.setState({ reviewed: event.target.checked })} />I reviewed the identifiers in these reports.</label>
        <button type="button" disabled=${!reviewed || !!waiting || !enabled} onClick=${() => this.download()}>Download reviewed bundle</button>
      </section>`
          : null
      }
      <${ServerHealth} state=${state} />
      <section class="panel"><h4>Help with mining</h4>
        <p>Waiting to mine: inspect node sync and pool readiness. An observed sync delay can explain a wait; it does not establish a fault.</p>
        <p>Hashrate dropped: check Machines for offline rigs, then review the health report. A missing worker sample is not zero hashrate.</p>
        <p>No payouts: inspect Earnings and share history. A share does not guarantee a payout, and recorded payouts are not wallet balance.</p>
        <p>Connecting a wallet: use the node connection instructions when available. Do not enter a spend key or seed phrase in diagnostics.</p>
        <p><a href="?page=machines">Machines</a> · <a href="?page=earnings">Earnings</a> · <a href="?page=settings&advanced=node-and-network">Node settings</a></p>
        <p>P2Pool console diagnostics are unavailable in this view. For missing or unsupported reports, use the host CLI or <a href="https://github.com/p2pool-starter-stack/pithead/issues">project support</a>. Review identifiers before sharing reports.</p>
      </section>
    </div>`;
  }
}

function value(value) {
  return value === null || value === undefined || value === "" ? "Not reported" : String(value);
}

export function ServerHealth({ state }) {
  const system = state?.system || {};
  const facts = [
    ["CPU usage", system.cpu?.percent],
    ["Load averages", system.cpu?.load],
    [
      "RAM used / total",
      system.mem?.used != null && system.mem?.total != null
        ? `${system.mem.used} / ${system.mem.total} GB`
        : null,
    ],
    ["Swap", system.swap?.used],
    [
      "Disk used / total",
      system.disk?.used != null && system.disk?.total != null && system.disk?.unit
        ? `${system.disk.used} / ${system.disk.total} ${system.disk.unit}`
        : null,
    ],
    ["HugePages", system.hugepages?.status],
    ["Server uptime", system.uptime],
    ["Pithead version", state?.version?.text],
    ["Snapshot time", state?.last_update],
    [
      "Database",
      state?.db_healthy === true
        ? "Writable"
        : state?.db_healthy === false
          ? "Needs attention"
          : null,
    ],
  ];
  return html`<section class="panel" aria-label="Server health"><h4>Server health</h4>
    <p>The Pithead server coordinates your rigs. A server without a local miner can still be healthy.</p>
    ${system.mem?.level === "high" || system.disk?.level === "high" ? html`<p class="notice">High memory or disk usage reported. Review the values below and the health report before changing settings.</p>` : null}
    <dl class="facts">${facts.map(([label, data]) => html`<div><dt>${label}</dt><dd>${value(data)}</dd></div>`)}</dl>
    <p>Resource history, storage forecasts and optional sensors are unavailable unless the host reports them.</p>
  </section>`;
}
