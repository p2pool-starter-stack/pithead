import { egressRoute } from "../app/logic.mjs";
import { html } from "../app/preact.mjs";
import { fmtEpoch } from "../system/securityview.mjs";
import { StackTopology } from "./topology.mjs";

const PING_REASON_LABELS = {
  tor_socks: "Tor proxy",
  dns: "name resolution",
  connect: "connection",
  http_status: "HTTP status",
};

// --- Operational view ----------------------------------------------------------------

// Component Health & egress posture (#170). The topology map (StackTopology) is the panel: every
// component and the route of each link, derived from live config (service/egress.py), so it can't
// drift from reality. The glanceable summary rides in the header badges + the line below; the older
// per-component egress list lives on as an expandable drawer for the full text detail / a11y.
function ComponentHealth({ topology, egress, ping_failures }) {
  if (!topology) return null;
  const { level, leaks } = topology.summary;
  const ok = level === "ok";
  const summaryClass = ok ? "ok" : leaks ? "bad" : "warn";
  const pings = Array.isArray(ping_failures) ? ping_failures : [];
  const pingsOk = pings.length === 0;
  return html`
    <div class="card card-advanced" id="card-egress">
        <h2>Stack Topology & Egress</h2>
        <div class=${"egress-summary c-" + summaryClass}>
            ${ok ? "🛡️" : "⚠️"} ${topology.summary.label}
        </div>
        <div class=${"ping-summary c-" + (pingsOk ? "ok" : "warn")}>
            <span class="egress-name">Monitoring ping</span>${" "}
            ${
              pingsOk
                ? html`<span class="ping-empty">No failed pings recorded.</span>`
                : html`<span class="ping-count">${pings.length} recent failure${pings.length === 1 ? "" : "s"}</span>`
            }
        </div>
        ${
          pingsOk
            ? null
            : html`<ul class="ping-failures">
                ${pings.map((f) => {
                  const label = PING_REASON_LABELS[f.reason] || f.reason;
                  return html`<li class="ping-failure">
                      <span class="ping-ts">${fmtEpoch(f.ts)}</span>
                      <span class="egress-route c-bad">${label}</span>${" "}
                      <span class="ping-detail">${f.detail || ""}</span>
                  </li>`;
                })}
              </ul>`
        }
        <${StackTopology} topology=${topology} />
        ${
          egress
            ? html`<details class="egress-details">
                <summary>All connections (per component)</summary>
                <div class="egress-list">
                    ${egress.components.map(
                      (comp) => html`
                        <div class="egress-component">
                            <div class="egress-name">${comp.name}</div>
                            <ul class="egress-conns">
                                ${comp.conns.map((conn) => {
                                  const r = egressRoute(conn.route);
                                  return html`
                                    <li class="egress-conn">
                                        <span class=${"egress-route c-" + r.cls}>${r.icon} ${r.label}</span>
                                        <span class="egress-to"
                                            >${conn.to}${
                                              conn.blocked_by_firewall
                                                ? html` <span class="egress-note">(firewall-blocked)</span>`
                                                : conn.chosen_clearnet
                                                  ? html` <span class="egress-note">(your choice: your IP is visible to this destination)</span>`
                                                  : ""
                                            }</span
                                        >
                                    </li>`;
                                })}
                            </ul>
                        </div>`,
                    )}
                </div>
              </details>`
            : ""
        }
    </div>`;
}

export { ComponentHealth };
