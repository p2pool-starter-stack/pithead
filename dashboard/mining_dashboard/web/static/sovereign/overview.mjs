import { Component, html } from "../app/preact.mjs";
import { verdictText } from "../system/osverdict.mjs";
import { OverviewChart } from "./overview-chart.mjs";
import {
  activityEntries,
  attention,
  link,
  number,
  overviewStatus,
  UNAVAILABLE,
} from "./overview-model.mjs";

export class Activity extends Component {
  constructor(props) {
    super(props);
    this.state = { audit: null, access: null, loading: true, range: "1m" };
  }
  componentDidMount() {
    this.load();
  }
  componentDidUpdate(previous) {
    if (previous.state?.last_update !== this.props.state?.last_update) this.load();
  }
  componentWillUnmount() {
    this.stopped = true;
    this.controller?.abort();
  }
  async load() {
    this.controller?.abort();
    const controller = new AbortController();
    this.controller = controller;
    const timer = setTimeout(() => controller.abort(), 8000);
    const seconds = { "24h": 86400, "1w": 604800, "1m": 2592000 }[this.state.range];
    const query = `?from=${seconds ? Date.now() / 1000 - seconds : 0}`;
    const read = async (path) => {
      try {
        const response = await (this.props.fetchFn || fetch)(`${path}${query}`, {
          signal: controller.signal,
          cache: "no-store",
        });
        if (!response.ok) return null;
        const data = await response.json();
        return data && Array.isArray(data.entries) ? data : null;
      } catch {
        return null;
      }
    };
    try {
      const [audit, access] = await Promise.all([read("/api/audit"), read("/api/access")]);
      if (!this.stopped && this.controller === controller)
        this.setState({ audit, access, loading: false });
    } finally {
      clearTimeout(timer);
    }
  }
  render({ state, full }, { audit, access, loading, range }) {
    const rows = activityEntries(state, audit, access);
    const cutoff =
      range === "all"
        ? 0
        : Date.now() / 1000 - { "24h": 86400, "1w": 604800, "1m": 2592000 }[range];
    const selected = rows.filter((entry) => entry.ts >= cutoff);
    return html`<section class="panel" aria-label=${full ? "Full Activity" : "Recent Activity"}><div class="overview-row"><h2>Activity</h2>
      ${
        full
          ? html`<label>Activity range <select value=${range} onChange=${(event) => this.setState({ range: event.target.value, loading: true }, () => this.load())}>
        <option value="24h">Day</option><option value="1w">Week</option><option value="1m">Month</option><option value="all">All retained</option></select></label>`
          : html`<a href=${link("overview", "activity")}>All retained activity</a>`
      }</div>
      ${loading ? html`<p>Loading recorded activity…</p>` : null}
      ${selected.length ? html`<ol class="activity-list">${(full ? selected : selected.slice(0, 10)).map((entry) => html`<li><time datetime=${new Date(entry.ts * 1000).toISOString()}>${new Date(entry.ts * 1000).toLocaleString()}</time><span>${entry.source} · ${entry.text}</span></li>`)}</ol>` : html`<p>No recorded activity in the available sources for this period.</p>`}
      ${!audit ? html`<p class="muted">Settings history is unavailable or the editor is off.</p>` : null}
      <p class="muted">${access?.available ? "Authenticated visits are access records; authentication does not record distinct session sign-ins." : "Access history is unavailable, empty or rotated."} ${state?.overview_activity?.truncated ? "Mining history is limited to the newest 1,000 retained entries." : "Mining history is independent of chart zoom when the host supplies it."} Retained logs may omit older entries.</p>
    </section>`;
  }
}

function value(field) {
  return field === undefined || field === null || field === "" ? UNAVAILABLE : field;
}

export function Overview({ state, connected, range, window, onRange, onWindow, fetchFn }) {
  const readings = state?.overview;
  const workers = state?.workers || [];
  const mining = workers.filter(
    (worker) => worker.status === "online" && number(worker.h60) && worker.h60 > 0,
  ).length;
  const last = state?.overview?.last_payout;
  const issues = attention(state);
  const fresh =
    connected &&
    number(readings?.snapshot_ts) &&
    Date.now() - readings.snapshot_ts * 1000 <= 120000;
  return html`<div class="overview-page"><section class="overview-hero" aria-label="Mining status">
    <p class=${fresh && !issues.length ? "status-ok" : "status-warn"} role="status">${overviewStatus(state, connected)}</p>
    <div class="overview-tiles">
      <article class="panel"><h2>Hashrate</h2><strong>${value(readings?.hashrate_now)}</strong><p>Now · ${value(state?.hashrate?.mode_name)}</p><p>24 h: ${value(readings?.hashrate_24h)}${fresh ? "" : " · last recorded"}</p></article>
      <article class="panel"><h2>Shares found</h2><strong>${value(readings?.shares_found)}</strong><p>Current P2Pool process counter; not a promised payout.</p></article>
      <article class="panel"><h2>Last payout</h2><strong>${last ? `${(last.amount / 1e12).toFixed(6)} XMR` : UNAVAILABLE}</strong><p>${last ? new Date(last.ts * 1000).toLocaleString() : "No confirmed payout reading; enable tracking in Advanced."}</p><a href=${link("earnings", "payout")}>Payout tracking</a></article>
    </div>
    <p><a href=${link("machines")}>Rigs · ${workers.length ? `${mining} of ${workers.length} mining` : "No rigs reported"}</a></p>
    <p>Nodes · Monero ${value(state?.sync?.monero?.state)}${readings?.tari_enabled ? ` · Tari ${value(state?.sync?.tari?.state)}` : ""}</p>
    <p>This machine · ${readings?.system_available ? `CPU ${readings.system_fields?.includes("cpu_percent") ? value(state?.system?.cpu?.percent) : UNAVAILABLE} · RAM ${readings.system_fields?.includes("memory") ? value(state?.system?.mem?.percent) : UNAVAILABLE} · Disk ${readings.system_fields?.includes("disk") ? value(state?.system?.disk?.percent) : UNAVAILABLE}` : UNAVAILABLE}</p>
    ${readings?.hugepages_available ? html`<p>HugePages · ${value(state?.system?.hugepages?.status)} · ${value(state?.system?.hugepages?.value)}</p>` : null}
    ${verdictText(state?.os_update?.verdict) ? html`<p class="notice">Appliance OS · ${verdictText(state.os_update.verdict)}</p>` : null}
  </section>
  <section class="panel" aria-label="Attention"><h2>Attention</h2>${!fresh ? html`<p>These conditions describe the last snapshot. Reconnect before acting.</p>` : null}
    ${issues.length ? html`<ul>${issues.map((item) => html`<li data-condition=${item.kind}><a href=${item.href}>${item.text}</a></li>`)}</ul>` : html`<p>No attention conditions reported in the available readings.</p>`}
    <p class="muted">Backup history, pool-tier advice and configuration warnings: ${readings?.attention_available ? "reported by the host" : "not reported by the host; unavailable"}.</p>
  </section>
  <${OverviewChart} state=${state} range=${range} window=${window} onRange=${onRange} onWindow=${onWindow} />
  <${Activity} state=${state} fetchFn=${fetchFn} />
  </div>`;
}

export function OverviewAdvanced({ section, state, range, window, onRange, onWindow, fetchFn }) {
  if (section === "activity")
    return html`<${Activity} state=${state} full=${true} fetchFn=${fetchFn} />`;
  if (section !== "inspect") return null;
  return html`<div><${OverviewChart} state=${state} range=${range} window=${window} onRange=${onRange} onWindow=${onWindow} advanced=${true} />
    <section class="panel"><h2>My node detail</h2><p>Monero · ${value(state?.monero?.mode)} · ${value(state?.monero?.health?.status)}</p><p>P2Pool effort · ${number(state?.overview?.effort) ? `${state.overview.effort.toFixed(1)}%` : UNAVAILABLE}</p></section>
    <section class="panel"><h2>Pool-wide statistics</h2><p>${value(state?.pool?.type)} · ${value(state?.pool?.hr)} · ${value(state?.pool?.miners)} miners</p></section>
    <section class="panel"><h2>Network</h2><p>Monero height ${value(state?.network?.height)} · ${value(state?.network?.diff)}</p></section>
    ${state?.overview?.xvb_enabled ? html`<section class="panel"><h2>XvB tier</h2><p>Current ${value(state?.hashrate?.tier)} · target ${value(state?.hashrate?.target_tier)}</p></section>` : null}
    <section class="panel"><h2>Configured topology</h2><p>Configured paths are not proof of reachability.</p><ul>${(state?.topology?.edges || []).map((edge) => html`<li>${edge.from} → ${edge.to} · ${edge.route}</li>`)}</ul></section>
  </div>`;
}
