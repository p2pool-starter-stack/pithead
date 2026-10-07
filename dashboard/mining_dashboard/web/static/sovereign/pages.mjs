import { ChartCard } from "../app/chart.mjs";
import { EarningsCard, ExpectedVsActualCard } from "../app/earnings.mjs";
import { Header } from "../app/header.mjs";
import {
  CadenceCard,
  GlobalStats,
  NetworkCard,
  NodeStats,
  TariCard,
  XvBStats,
} from "../app/overview.mjs";
import { Component, createRef, html } from "../app/preact.mjs";
import { ConfigView } from "../config/configview.mjs";
import { ComponentHealth } from "../network/health.mjs";
import { BackupPanel } from "../system/backupview.mjs";
import { DiagnosticsPanel } from "../system/diagview.mjs";
import { SecurityPanel } from "../system/securityview.mjs";
import { WorkersTable } from "../workers/workertable.mjs";

// Keep this editor mounted across local navigation. The native unload prompt covers reload,
// closing the tab and leaving the preview, without serializing secrets into browser storage.
export class SettingsPage extends Component {
  constructor(props) {
    super(props);
    this.editor = createRef();
    this.beforeUnload = (event) => {
      const s = this.editor.current?.state;
      if (s && (s.editText !== s.pristine || ["previewing", "committing"].includes(s.phase))) {
        event.preventDefault();
        event.returnValue = "";
      }
    };
  }
  componentDidMount() {
    globalThis.addEventListener("beforeunload", this.beforeUnload);
  }
  componentWillUnmount() {
    globalThis.removeEventListener("beforeunload", this.beforeUnload);
  }
  render() {
    return html`<div class="card-stack"><p class="sov-note">Edits stay here while you visit other pages. Review the changes before applying them.</p>
      <${ConfigView} ref=${this.editor} appliance=${!!this.props.state.os_update} /></div>`;
  }
}

function Pulse(props) {
  const { state, ui } = props;
  return html`<${ChartCard} chart=${state.chart} range=${ui.range} window=${ui.window} series=${ui.series}
    xvbHistory=${state.xvb_history} avgWindow=${ui.avg} onRange=${props.onRange}
    onZoom=${props.onZoom} onResetZoom=${props.onResetZoom}
    onToggleSeries=${props.onToggleSeries} onAvgWindow=${props.onAvgWindow} />`;
}

class MachinesPage extends Component {
  constructor(props) {
    super(props);
    this.state = { search: "", attention: false, connection: false, addresses: false };
  }
  render() {
    const { state, ui, onSort, onInspect } = this.props;
    const all = state.workers || [];
    const needsAttention = (w) =>
      w.status !== "online" || w.api_ok === false || w.reject_flag || w.rigforge?.miner_down;
    const visible = all.filter(
      (w) =>
        w.name.toLowerCase().includes(this.state.search.toLowerCase()) &&
        (!this.state.attention || needsAttention(w)),
    );
    const online = all.filter((w) => w.status === "online").length;
    return html`<div class="card-stack">
      <div class="sov-metrics">
        <div><span>Total hashrate</span><strong>${state.hashrate.total}</strong><small>Reported by the proxy</small></div>
        <div><span>Workers online</span><strong>${online} <em>of ${all.length}</em></strong><small>Worker identities, not a physical machine count</small></div>
        <div><span>Share rejection</span><strong>${state.proxy_summary?.has_data ? state.proxy_summary.reject_pct : "—"}</strong><small>${state.proxy_summary?.has_data ? "From the proxy's recorded shares" : "No share totals reported"}</small></div>
      </div>
      <div class="sov-toolbar"><label class="sov-search">Search workers<input type="search" placeholder="Find a worker…" value=${this.state.search} onInput=${(e) => this.setState({ search: e.target.value })} /></label>
        <button class="btn-toggle" type="button" aria-pressed=${this.state.attention} onClick=${() => this.setState({ attention: !this.state.attention })}>Needs attention (${all.filter(needsAttention).length})</button>
        <button class="sov-button" type="button" aria-expanded=${this.state.connection} onClick=${() => this.setState({ connection: !this.state.connection })}>＋ Connect a worker</button></div>
      ${
        this.state.connection
          ? html`<div class="card"><h2>Connect to your stack</h2><p>Use the worker connection guide to configure the endpoint and any required TLS or authentication.</p>
        <p>Mining through the proxy does not enroll a worker for management. Open a worker to inspect its available controls and adoption status.</p>
        <a href="https://github.com/p2pool-starter-stack/pithead/blob/main/docs/workers.md" target="_blank" rel="noopener noreferrer">Open the connection guide ↗</a></div>`
          : null
      }
      <button class="btn-link" type="button" aria-pressed=${this.state.addresses} onClick=${() => this.setState({ addresses: !this.state.addresses })}>${this.state.addresses ? "Hide worker addresses" : "Reveal worker addresses"}</button>
      ${
        visible.length || !all.length
          ? html`<${WorkersTable} workers=${visible} summary=${state.proxy_summary} ui=${ui} onSort=${onSort}
        hostIp=${state.host_ip && state.host_ip !== "Unknown Host" ? state.host_ip : state.host_addr} stratumPort=${state.stratum_port} maskAddresses=${!this.state.addresses} onInspect=${state.control_enabled ? onInspect : null} />`
          : html`<div class="card"><h2>No matching workers</h2><p>Try another name or turn off the attention filter.</p></div>`
      }
      <${Pulse} ...${this.props} />
      <details class="card sov-server"><summary>Pithead server · CPU ${state.system.cpu.percent} · RAM ${state.system.mem.percent}</summary>
        <${Header} state=${state} theme=${ui.theme} onTheme=${this.props.onTheme} /></details>
    </div>`;
  }
}

export function activityRows(state) {
  return [
    ...(state.chart?.events || []).map((e) => ({ ...e, source: "Mining event" })),
    ...(state.chart?.payouts || []).map((e) => ({ ...e, source: "Recorded payout" })),
    ...(state.chart?.raffle || []).map((e) => ({ ...e, source: "XvB raffle" })),
  ]
    .filter((e) => Number.isFinite(e.x))
    .sort((a, b) => b.x - a.x)
    .slice(0, 50);
}

function ActivityPage({ state }) {
  const rows = activityRows(state);
  return html`<div class="card-stack"><div class="card"><h2>Recent mining activity</h2>
    <p class="sov-note">Up to 50 events from the selected chart range. Access and configuration records are below.</p>
    ${
      rows.length
        ? html`<ol class="sov-timeline">${rows.map((e) => html`<li><span class="sov-eyebrow">${e.source}</span><p>${e.label}</p><time datetime=${new Date(e.x).toISOString()}>${new Date(e.x).toLocaleString()}</time></li>`)}</ol>`
        : html`<p>No mining events recorded in this range.</p>`
    }</div><${SecurityPanel} /></div>`;
}

export function PageContent(props) {
  const { state, page, onView } = props;
  if (page === "machines") return html`<${MachinesPage} ...${props} />`;
  if (page === "earnings")
    return html`<div class="sov-two-column">
    <${EarningsCard} earnings=${state.earnings} xvb=${state.xvb_calc} energy=${state.energy} />
    <div class="card-stack"><${ExpectedVsActualCard} summary=${state.earnings_summary} onView=${onView} />
      <${CadenceCard} cadence=${state.cadence} /><${XvBStats} state=${state} /></div></div>`;
  if (page === "network")
    return html`<div class="card-stack"><p class="sov-note">Routes describe configuration. They do not establish anonymity or prove the route of every live connection.</p>
    <${ComponentHealth} topology=${state.topology} egress=${state.egress} />
    <div class="sov-two-column"><${NetworkCard} state=${state} /><${GlobalStats} state=${state} />
      <${NodeStats} state=${state} showWallet=${false} />${state.tari?.active ? html`<${TariCard} tari=${state.tari} local=${state.sync?.tari?.local} showWallet=${false} />` : null}</div></div>`;
  if (page === "activity") return html`<${ActivityPage} state=${state} />`;
  if (page === "maintenance")
    return html`<div class="card-stack"><${BackupPanel} enabled=${state.control_enabled} appliance=${!!state.os_update} />
    <${DiagnosticsPanel} enabled=${state.control_enabled} /><details class="card sov-server"><summary>Versions and updates</summary>
      <${Header} state=${state} theme=${props.ui.theme} onTheme=${props.onTheme} /></details></div>`;
  return html`<div class="sov-help-grid">
    <a class="card" href="#machines"><h2>Bring a worker online <span>↗</span></h2><p>Connection guidance, worker health and available management controls.</p></a>
    <a class="card" href="#network"><h2>Understand your nodes <span>↗</span></h2><p>Chain progress, pool statistics and configured network routes.</p></a>
    <a class="card" href="#maintenance"><h2>Find a problem <span>↗</span></h2><p>Service diagnostics, encrypted backups and update controls.</p></a>
    <a class="card" href="https://github.com/p2pool-starter-stack/pithead/tree/main/docs" target="_blank" rel="noopener noreferrer"><h2>Read the handbook <span>↗</span></h2><p>Operator documentation. Opens the project on GitHub.</p></a>
    <div class="card"><h2>About this preview</h2><p>Sovereign is being developed for after 2.0.0. This preview uses the existing dashboard APIs; fleet jobs, new telemetry and setup changes are still separate work.</p><a href="/">Return to the classic dashboard →</a></div>
  </div>`;
}
