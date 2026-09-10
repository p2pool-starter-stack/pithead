import { egressRoute } from "../app/logic.mjs";
import { html } from "../app/preact.mjs";
import { StackTopology } from "./topology.mjs";

// --- Operational view ----------------------------------------------------------------

// Component Health & egress posture (#170). The topology map (StackTopology) is the panel: every
// component and the route of each link, derived from live config (service/egress.py), so it can't
// drift from reality. The glanceable summary rides in the header badges + the line below; the older
// per-component egress list lives on as an expandable drawer for the full text detail / a11y.
function ComponentHealth({ topology, egress }) {
  if (!topology) return null;
  const ok = topology.summary.level === "ok";
  return html`
    <div class="card card-advanced" id="card-egress">
        <h3>Stack Topology & Egress</h3>
        <div class=${"egress-summary c-" + (ok ? "ok" : "bad")}>
            ${ok ? "🛡️" : "⚠️"} ${topology.summary.label}
        </div>
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
