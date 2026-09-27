import { ChartCard } from "../app/chart.mjs";
import { formatXmr } from "../app/logic.mjs";
import { html } from "../app/preact.mjs";
import { TariStatus } from "../system/statcards.mjs";
import { NetworkArt } from "./network-art.mjs";

const go = (onView, page) => () => onView(page);

function Hero({ state, onView }) {
  const total = String(state.hashrate?.total || "—");
  const match = total.match(/^(.+?)\s+([^\s]+)$/);
  const connected = Number.isFinite(state.proxy_workers) ? state.proxy_workers : null;
  return html`
    <section class="sov-hero" aria-labelledby="sov-title">
      <div class="sov-hero-copy">
        <h2 id="sov-title"><span>Own the whole</span><br />operation.</h2>
        <p class="sov-deck">Your Monero mining stack, under your control.</p>
        <div class="sov-hashrate">
          <span class="sov-label">Current proxy hashrate</span>
          <strong>${match ? match[1] : total}${match ? html` <small class="sov-unit">${match[2]}</small>` : null}</strong>
          <span>${connected ?? "—"} connected worker${connected === 1 ? "" : "s"}</span>
        </div>
        ${
          state.xvb_calc?.enabled
            ? html`<div class="sov-xvb-facts">
                <span>XvB routed <strong>${state.hashrate?.xvb_routed_1h || "—"}</strong> · 1 hour</span>
                <span>Eligibility <strong>${state.hashrate?.tier || "None"}</strong></span>
              </div>`
            : null
        }
        ${state.tari?.active ? html`<div class="sov-tari"><span>Tari merge mining</span><${TariStatus} tari=${state.tari} /></div>` : null}
        <div class="sov-actions">
          <button type="button" class="sov-button" onClick=${go(onView, "machines")}>Tune mining</button>
          <button type="button" class="sov-link" onClick=${go(onView, "activity")}>View activity <span aria-hidden="true">→</span></button>
        </div>
      </div>
      <${NetworkArt} />
    </section>`;
}

function Metrics({ state }) {
  const xmr = state.earnings_summary?.xmr;
  const recorded = xmr?.enabled && xmr.actual_30d != null;
  const partial = recorded && xmr.partial;
  const shares = state.shares_window?.ok ? state.shares_window.count : null;
  return html`
    <section class="sov-metrics" aria-label="Mining summary">
      <div class="sov-metric">
        <span>Recorded XMR · 30 days${partial ? " *" : ""}</span>
        <strong>${recorded ? formatXmr(xmr.actual_30d) : "—"}</strong>
        <small>${recorded ? (partial ? "Partial payout history" : "Confirmed payouts") : "Payout tracking unavailable"}</small>
      </div>
      <div class="sov-metric">
        <span>Shares in window</span>
        <strong>${Number.isFinite(shares) ? shares : "—"}</strong>
        <small>Current PPLNS window</small>
      </div>
      <div class="sov-metric">
        <span>P2Pool routed · 24 hours</span>
        <strong>${state.hashrate?.p2p_24h || "—"}</strong>
        <small>Average routed hashrate</small>
      </div>
    </section>`;
}

function WorkerRow({ worker, onInspect }) {
  const body = html`
    <span class="sov-worker-name">${worker.name}</span>
    <span class="sov-worker-rate">${worker.h60_str || "—"}</span>
    <span class=${`sov-worker-status is-${worker.status || "unknown"}`}>${worker.status || "unknown"}</span>`;
  return onInspect
    ? html`<button type="button" class="sov-worker" onClick=${() => onInspect(worker.name)}>${body}</button>`
    : html`<div class="sov-worker">${body}</div>`;
}

function attentionItems(state) {
  const items = [];
  const add = (label, page) => items.push({ label, page });
  const workers = (state.workers || []).filter(
    (worker) =>
      worker.status !== "online" ||
      worker.api_ok === false ||
      worker.reject_flag ||
      worker.rigforge?.miner_down,
  ).length;
  if (workers)
    add(
      `${workers} worker feed${workers === 1 ? "" : "s"} need${workers === 1 ? "s" : ""} attention`,
      "machines",
    );
  if (state.proxy_summary?.reject_level === "high")
    add(`Proxy rejects ${state.proxy_summary.reject_pct}`, "machines");
  if (!state.sync?.monero) add("Monero sync unavailable", "network");
  else if (state.sync.monero.state !== "done")
    add(`Monero sync ${state.sync.monero.percent ?? "—"}%`, "network");
  if (state.tari?.active && !state.tari.connected) add(`Tari: ${state.tari.status}`, "network");
  const topology = state.topology?.summary;
  if (!topology) add("Configured egress unavailable", "network");
  else if (topology.level !== "ok")
    add(`Configured egress: ${topology.label || "unverified"}`, "network");
  for (const [name, label] of [
    ["cpu", "CPU"],
    ["mem", "Memory"],
    ["disk", "Disk"],
  ]) {
    const metric = state.system?.[name];
    if (!metric?.level) add(`${label} unavailable`, "maintenance");
    else if (metric.level !== "ok")
      add(`${label} ${metric.percent || metric.level}`, "maintenance");
  }
  if (state.shares_window?.ok === false) add("Share window unavailable", "activity");
  if (state.db_healthy === false) add("Dashboard database needs attention", "maintenance");
  if (state.update?.available) add(`Pithead ${state.update.latest} available`, "maintenance");
  return items;
}

function Operation({ state, onView }) {
  const sync = state.sync?.monero;
  const moneroState = sync
    ? sync.state === "done"
      ? `Synced · ${sync.current}`
      : `${sync.percent}% · ${sync.remaining} blocks remaining`
    : "Unknown";
  const local = sync?.local === true ? "Local" : sync?.local === false ? "Remote" : "Unknown";
  const attention = attentionItems(state);
  const topology = state.topology?.summary;
  return html`
    <aside class="sov-operation">
      <div class="sov-panel-heading">
        <div><p class="sov-eyebrow">Stack facts</p><h2>Your operation</h2></div>
        <button type="button" class="sov-link" onClick=${go(onView, "network")}>Network →</button>
      </div>
      <dl class="sov-facts">
        <div><dt>Monero node</dt><dd>${local} · ${moneroState}</dd></div>
        <div><dt>P2Pool routed</dt><dd>${state.hashrate?.p2p_1h || "—"} / ${state.hashrate?.p2p_24h || "—"}</dd></div>
        <div><dt>Last share</dt><dd>${state.stratum?.last_share || "—"}</dd></div>
        <div><dt>Configured egress</dt><dd>${topology?.label || "Unavailable"}</dd></div>
      </dl>
      <div class="sov-attention">
        <div class="sov-panel-heading">
          <h3>Attention</h3>
        </div>
        ${
          attention.length
            ? html`<ul>${attention.map(
                (item) =>
                  html`<li><button type="button" class="sov-link" onClick=${go(onView, item.page)}>${item.label} →</button></li>`,
              )}</ul>`
            : html`<p>No attention items in current dashboard data.</p>`
        }
      </div>
    </aside>`;
}

function Pulse({ state, ui, onRange, onZoom, onResetZoom, onToggleSeries, onAvgWindow }) {
  return html`
    <section class="sov-pulse" aria-labelledby="sov-pulse-title">
      <div class="sov-panel-heading"><div><p class="sov-eyebrow">Routed work</p><h2 id="sov-pulse-title">Mining pulse</h2></div></div>
      <div class="sov-chart-card">
        <${ChartCard} compact=${true} chart=${state.chart} range=${ui.range} window=${ui.window} series=${ui.series}
          xvbHistory=${state.xvb_history} avgWindow=${ui.avg} onRange=${onRange} onZoom=${onZoom}
          onResetZoom=${onResetZoom} onToggleSeries=${onToggleSeries} onAvgWindow=${onAvgWindow} />
      </div>
    </section>`;
}

function Workers({ state, onView, onInspect }) {
  const workers = state.workers || [];
  const shown = workers.slice(0, 5);
  return html`
    <section class="sov-workers" aria-labelledby="sov-workers-title">
      <div class="sov-panel-heading">
        <div><p class="sov-eyebrow">Reported worker feeds</p><h2 id="sov-workers-title">Workers</h2></div>
        <button type="button" class="sov-link" onClick=${go(onView, "machines")}>${workers.length > 5 ? `All ${workers.length} workers` : "All workers"} →</button>
      </div>
      <div class="sov-worker-list">
        ${
          shown.length
            ? shown.map(
                (worker) =>
                  html`<${WorkerRow} key=${worker.name} worker=${worker} onInspect=${onInspect} />`,
              )
            : html`<p class="sov-empty">No worker feeds reported.</p>`
        }
      </div>
    </section>`;
}

export function SovereignOverview({
  state,
  ui,
  onView,
  onRange,
  onZoom,
  onResetZoom,
  onToggleSeries,
  onAvgWindow,
  onInspect,
}) {
  return html`
    <div class="sov-overview">
      <${Hero} state=${state} onView=${onView} />
      <${Metrics} state=${state} />
      <div class="sov-dashboard-grid">
        <div>
          <${Pulse} state=${state} ui=${ui} onRange=${onRange} onZoom=${onZoom}
            onResetZoom=${onResetZoom} onToggleSeries=${onToggleSeries} onAvgWindow=${onAvgWindow} />
          <${Workers} state=${state} onView=${onView} onInspect=${state.control_enabled ? onInspect : null} />
        </div>
        <${Operation} state=${state} onView=${onView} />
      </div>
    </div>`;
}
