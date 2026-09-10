import { sortWorkers, uptimeCell, WORKER_COLUMNS } from "../app/logic.mjs";
import { html } from "../app/preact.mjs";

// --- Workers table (WORKER_COLUMNS + sortWorkers live in logic.mjs, unit-tested) -----

function PoolBadge({ pool }) {
  if (pool === "p2pool") return html`<span class="badge badge-ok">P2Pool</span>`;
  if (pool === "xvb") return html`<span class="badge badge-purple">XvB</span>`;
  return html`<span class="badge badge-bad">Unknown</span>`;
}

// RigForge enriched feed (#235): a monospace version badge plus health / power / tune / watchdog
// chips, all built server-side (infra_views._rigforge_display) so the client stays a dumb renderer.
// A plain-xmrig worker has no `rigforge` block and renders nothing extra — no chips, no error, no
// empty placeholder, exactly as today. Each chip is a {text, variant, title}; only present-data
// chips are emitted, so a rig with no RAPL shows no power chip.
function RigForgeChips({ rf }) {
  if (!rf) return null;
  return html`${
    rf.version
      ? html` <span class="badge badge-outline version-badge" title="RigForge version">rf ${rf.version}</span>`
      : null
  }${(rf.chips || []).map(
    (c) => html` <span class=${"badge badge-" + c.variant} title=${c.title || ""}>${c.text}</span>`,
  )}`;
}

// Per-worker RigForge new-release callout (#596) — the worker-level twin of UpdateBadge. Opens
// Worker Inspect (#893) so the gated/upgrade state can explain itself; the release-notes link
// moves inside the dialog. No dialog (control channel off) falls back to the old link-only badge.
const RigUpdateBadge = ({ up, name, onInspect }) => {
  if (!up || !up.available) return null;
  const title = "A newer RigForge release is available: " + up.latest,
    label = html`rf ${up.latest} available ↗`;
  if (onInspect)
    return html` <button type="button" class="badge badge-accent" onClick=${() => onInspect(name)} title=${title}>${label}</button>`;
  return up.url
    ? html` <a class="badge badge-accent" href=${up.url} target="_blank" rel="noopener noreferrer" title=${title}>${label}</a>`
    : null;
};

// The worker's xmrig-API badge (#1857). One probe verdict answers two different questions and the
// row has to tell them apart: an ADOPTED rig whose configured feed then failed is a real fault, and
// the red badge's config advice is right for it; a rig the dashboard holds no control token for
// gets the neutral `badge-outline` the version badge uses (#1836). That is NOT a claim it is
// healthy: `workers.list` defaults to [], so a hand-configured miner with a real API fault lands
// here too, and the tooltip names BOTH remedies rather than promising adoption fixes it.
// The tooltip branches on `onInspect` for the same reason the name button does: with dashboard
// control off there is no way into the rig from this table and no Adopt form (workerview.mjs), so
// "open it and adopt" would be an impossible instruction. When control IS on it renders as a
// button, like RigUpdateBadge, so the tooltip carrying the instruction is keyboard-reachable.
const ApiBadge = ({ w, onInspect }) => {
  if (w.api_ok !== false) return null;
  if (w.adopted)
    return html` <span class="badge badge-bad" title="The dashboard couldn't read this worker's xmrig API, so uptime and per-miner hashrate are unavailable (it still mines — figures come from the proxy). Check workers.api_auth / api_port, or the miner's xmrig http settings.">api ⚠</span>`;
  const title =
    "This rig mines through the proxy, but the dashboard could not read its stats, and it holds no control token for it. " +
    (onInspect
      ? "A rig set up by the setup wizard needs adopting: open it from its name in this table and choose Adopt this rig. "
      : "A rig set up by the setup wizard needs adopting, which needs dashboard.control on and a dashboard password. ") +
    "A miner you configured yourself needs its xmrig API checked: workers.api_auth / api_port, or the miner's xmrig http settings.";
  return onInspect
    ? html` <button type="button" class="badge badge-outline" onClick=${() => onInspect(w.name)} title=${title}>not adopted</button>`
    : html` <span class="badge badge-outline" title=${title}>not adopted</span>`;
};

// Pool-wide proxy share totals (Issue #82) — a footer under the table. Hidden until the proxy
// has reported any shares so it isn't an all-zero line on a fresh start.
const ProxyTotals = ({ summary }) => {
  if (!summary || !summary.has_data) return null;
  // htm trims whitespace that wraps across a newline at an element boundary, so the spaces
  // around the rejected <span> are added explicitly via ${' '} rather than left to indentation.
  const rejCls = summary.reject_level === "high" ? "status-bad" : "";
  return html`
    <div class="proxy-totals text-small text-muted">
        Proxy totals: <span class="status-ok">${summary.accepted}</span> accepted ·${" "}
        <span class=${rejCls}>${summary.rejected}</span> rejected (${summary.reject_pct}) ·${" "}
        ${summary.invalid} invalid · Best diff ${summary.best}
    </div>`;
};

function WorkersTable({ workers, summary, ui, onSort, hostIp, stratumPort, onInspect }) {
  // First-run empty state (#385): show the one action to take instead of empty headers.
  // `workers` includes offline rigs, so a temporarily all-offline fleet keeps its (red) table.
  if ((workers || []).length === 0) {
    const addr = hostIp && hostIp !== "Unknown Host" ? hostIp : "YOUR_STACK_IP";
    const port = stratumPort || 3333; // configurable via p2pool.stratum_port (#172)
    return html`
        <div class="card">
            <h3>Workers Alive</h3>
            <div class="workers-empty">
                <p>No workers connected yet.</p>
                <p class="text-muted">Point each rig at <code>${addr}:${port}</code> and it appears here —${" "}
                    see the <a href="https://github.com/p2pool-starter-stack/pithead/blob/main/docs/workers.md"
                        target="_blank" rel="noopener noreferrer">workers guide</a>.</p>
            </div>
        </div>`;
  }
  const rows = sortWorkers(workers, ui.sortIndex, ui.sortAsc);
  return html`
    <div class="card">
        <h3>Workers Alive</h3>
        <div class="table-scroll">
            <table id="workers-table">
                <thead>
                    <tr>${WORKER_COLUMNS.map(
                      // Sorted column carries the direction, visibly (arrow) and for AT (aria-sort);
                      // the title makes clickability discoverable (#656). A real <button> click
                      // target so keyboard users can sort too (#671), focusable without extra wiring.
                      (c, i) => html`<th
                            class=${i === ui.sortIndex ? "sorted" : null}
                            aria-sort=${i === ui.sortIndex ? (ui.sortAsc ? "ascending" : "descending") : null}><button
                              type="button" class="th-sort-btn" onClick=${() => onSort(i)}
                              title=${"Sort by " + c.label}>${c.label}${
                                i === ui.sortIndex
                                  ? html`<span class="sort-arrow">${ui.sortAsc ? " ▲" : " ▼"}</span>`
                                  : ""
                              }</button></th>`,
                    )}</tr>
                </thead>
                <tbody id="workers-tbody">
                    ${rows.map(
                      (w) => html`
                        <tr class=${w.status === "online" ? "status-ok" : "status-bad"}>
                            <td>${
                              onInspect
                                ? html`<button type="button" class="worker-name-link" onClick=${() => onInspect(w.name)}
                                                title="Inspect / edit this worker's config">${w.name}</button>`
                                : w.name
                            } <${PoolBadge} pool=${w.pool} /><${ApiBadge} w=${w} onInspect=${onInspect} /><${RigForgeChips} rf=${w.rigforge} /><${RigUpdateBadge} up=${w.rigforge_update} name=${w.name} onInspect=${onInspect} /></td>
                            <td>${w.ip}</td>
                            <td>${uptimeCell(w)}</td>
                            <td>${w.h60_str}</td>
                            <td>${w.h15_str}</td>
                            <td>${w.accepted_str}</td>
                            <td>${w.rejected_str}${
                              w.reject_flag
                                ? html` <span class="badge badge-bad" title=${w.reject_flag.title}>${w.reject_flag.text}</span>`
                                : null
                            }</td>
                        </tr>`,
                    )}
                </tbody>
            </table>
        </div>
        <${ProxyTotals} summary=${summary} />
    </div>`;
}

export { WorkersTable };
