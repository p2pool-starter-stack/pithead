import { ConfigView } from "../config/configview.mjs";
import { ComponentHealth } from "../network/health.mjs";
import { MineCartTrain } from "../network/minecart.mjs";
import { BackupPanel } from "../system/backupview.mjs";
import { DiagnosticsPanel } from "../system/diagview.mjs";
import { OsVerdictBanner } from "../system/osupdate.mjs";
import { SecurityPanel } from "../system/securityview.mjs";
import { SyncView } from "../system/syncview.mjs";
import { WorkersTable } from "../workers/workertable.mjs";
import { WorkerInspect } from "../workers/workerview.mjs";
import { ChartCard } from "./chart.mjs";
import { EarningsCard, ExpectedVsActualCard } from "./earnings.mjs";
import { Header } from "./header.mjs";
import {
  CadenceCard,
  GlobalStats,
  NetworkCard,
  NodeStats,
  Overview,
  TariCard,
  XvBStats,
} from "./overview.mjs";
import { Fragment, html } from "./preact.mjs";
import { HeroBand, ThemeSwitcher } from "./ui.mjs";

// One-time discoverability hint (#425): the earnings + XvB tier calculators are Advanced-view
// cards, invisible from the default Simple view. Points at Advanced until the operator acts on
// it (the inline button switches views; dashboard.js retires the hint on any Advanced visit) or
// dismisses it outright; `ui.hintDismissed` persists in localStorage, so it shows once per browser.
function AdvancedHint({ ui, onView, onDismissHint }) {
  if (ui.view !== "simple" || ui.hintDismissed) return null;
  return html`
    <div class="advanced-hint" id="advanced-hint">
        <span>Looking for earnings estimates or the XvB tier calculator? They live in${" "}
            <button type="button" class="btn-link" onClick=${() => onView("advanced")}>Advanced view</button>.</span>
        <button type="button" class="advanced-hint-dismiss" aria-label="Dismiss hint"
                title="Dismiss" onClick=${onDismissHint}>×</button>
    </div>`;
}

function DashboardView({
  state,
  ui,
  onRange,
  onSort,
  onView,
  onZoom,
  onResetZoom,
  onToggleSeries,
  onAvgWindow,
  onDismissHint,
  onInspect,
}) {
  const advanced = ui.view === "advanced";
  const configView = ui.view === "config";
  // Backup is its own view, not a card below the config editor (#1854): an operator handed a
  // working machine has to be able to find "take a backup" without reading the editor first.
  const backupView = ui.view === "backup";
  // Layout by operator relevance (#159): the at-a-glance chart and the rigs themselves lead (this
  // stack may drive many machines), then this stack's own detail cards, then pool-wide and network
  // context as reference at the bottom — "mine" first, "the world" last.
  // Within "Your Stack" (#991, reopened): the section packs into CSS columns now, not CSS grid
  // rows, so a card's height no longer forces blank space under a shorter neighbour regardless of
  // which cards a given render state actually shows (XvB disabled, no earnings yet, ...) — the
  // tall-with-tall/short-with-short pairing this comment used to describe was a workaround for
  // grid's row-stretch behaviour and is moot under column packing. Order here still sets the
  // column-major reading order, so it stays "mine" first, "the world" last, same as above.
  // Overview is Simple-view-only (display:none in Advanced) and ExpectedVsActualCard shows in
  // both views — neither is constrained by this ordering.
  return html`
    <div id="dashboard-view" class=${advanced ? "mode-advanced" : ""}>
        <div class="view-controls">
            <div class="toggle-group" role="group" aria-label="Dashboard view">
                <button class=${"btn-toggle" + (!advanced && !configView && !backupView ? " active" : "")} aria-pressed=${!advanced && !configView && !backupView}
                    title="Chart, workers and the headline numbers" onClick=${() => onView("simple")}>Simple</button>
                <button class=${"btn-toggle" + (advanced ? " active" : "")} aria-pressed=${advanced}
                    title="Every stats card, calculators and diagnostics" onClick=${() => onView("advanced")}>Advanced</button>
                <button class=${"btn-toggle" + (configView ? " active" : "")} aria-pressed=${configView}
                    title="View or edit the stack configuration" onClick=${() => onView("config")}>Configuration</button>
                <button class=${"btn-toggle" + (backupView ? " active" : "")} aria-pressed=${backupView}
                    title="Export an encrypted copy of this machine's configuration and secrets" onClick=${() => onView("backup")}>Backup</button>
            </div>
        </div>
        <${AdvancedHint} ui=${ui} onView=${onView} onDismissHint=${onDismissHint} />
        ${
          configView
            ? html`<div class="card-stack"><${ConfigView} appliance=${!!state.os_update} /><${DiagnosticsPanel} enabled=${state.control_enabled} /><${SecurityPanel} /></div>`
            : null
        }
        ${
          backupView
            ? html`<div class="card-stack"><${BackupPanel} enabled=${state.control_enabled} appliance=${!!state.os_update} /></div>`
            : null
        }
        ${
          configView || backupView
            ? null
            : html`
        <div class="grid">
            <${ChartCard} chart=${state.chart} range=${ui.range} window=${ui.window} series=${ui.series}
                          xvbHistory=${state.xvb_history} avgWindow=${ui.avg}
                          onRange=${onRange} onZoom=${onZoom} onResetZoom=${onResetZoom}
                          onToggleSeries=${onToggleSeries} onAvgWindow=${onAvgWindow} />
        </div>
        <div class="grid">
            <${WorkersTable} workers=${state.workers} summary=${state.proxy_summary} ui=${ui} onSort=${onSort} hostIp=${state.host_ip} stratumPort=${state.stratum_port}
                             onInspect=${state.control_enabled ? onInspect : null} />
        </div>
        <div class="grid-section-label">Your Stack</div>
        <div class="grid grid-columns">
            <${Overview} state=${state} />
            <${XvBStats} state=${state} />
            <${EarningsCard} earnings=${state.earnings} xvb=${state.xvb_calc} energy=${state.energy} />
            <${NodeStats} state=${state} />
            <${ExpectedVsActualCard} summary=${state.earnings_summary} />
            <${TariCard} tari=${state.tari} local=${state.sync?.tari?.local} />
            <${CadenceCard} cadence=${state.cadence} />
        </div>
        <div class="grid-section-label">The Wider Pool</div>
        <div class="grid grid-columns">
            <${GlobalStats} state=${state} />
            <${NetworkCard} state=${state} />
            <${ComponentHealth} topology=${state.topology} egress=${state.egress} />
        </div>`
        }
    </div>`;
}

// --- Root ----------------------------------------------------------------------------

export function App({
  state,
  connected,
  ui,
  onRange,
  onSort,
  onView,
  onTheme,
  onZoom,
  onResetZoom,
  onToggleSeries,
  onAvgWindow,
  onDismissHint,
  onInspect,
  onCloseInspect,
}) {
  // The theme toggle is fixed-position and always available, even before the first data load.
  const switcher = html`<${ThemeSwitcher} theme=${ui.theme} onTheme=${onTheme} />`;
  // Worker Inspect overlay (#185): opened from a worker name in the table; the panel does its own
  // fetch/apply/poll. `key` remounts it when a different worker is picked. Only reachable when the
  // control channel is on (the trigger is gated on state.control_enabled).
  const inspect =
    state && ui.inspectWorker
      ? html`<${WorkerInspect} name=${ui.inspectWorker} onClose=${onCloseInspect} key=${ui.inspectWorker} />`
      : null;
  if (!state) {
    return html`<${Fragment}>
            <div class="loading">${
              connected
                ? "Connecting to the dashboard… If this machine is still syncing its first chain, progress appears here in a moment."
                : "Cannot reach the dashboard."
            }</div>
            ${switcher}
        <//>`;
  }
  return html`<${Fragment}>
        <${Header} state=${state} />
        <${OsVerdictBanner} os=${state.os_update} />
        ${!connected ? html`<div class="disconnected-banner">Disconnected — showing data from ${state.last_update}. Retrying…</div>` : null}
        ${
          state.syncing
            ? html`<${SyncView} sync=${state.sync} />`
            : html`<${Fragment}>
                <${HeroBand} state=${state} />
                <${MineCartTrain} chart=${state.chart} blocks=${state.blocks} payouts=${state.payouts} />
                <${DashboardView} state=${state} ui=${ui} onRange=${onRange} onSort=${onSort}
                                  onView=${onView} onZoom=${onZoom} onResetZoom=${onResetZoom}
                                  onToggleSeries=${onToggleSeries} onAvgWindow=${onAvgWindow}
                                  onDismissHint=${onDismissHint} onInspect=${onInspect} />
              <//>`
        }
        ${inspect}
        ${switcher}
    <//>`;
}
