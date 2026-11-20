import { html } from "../app/preact.mjs";

const when = (epoch) =>
  Number.isFinite(epoch) ? new Date(epoch * 1000).toISOString().replace(".000Z", "Z") : "unknown";

const age = (sec) => (Number.isFinite(sec) ? `${Math.round(sec / 60)} min` : "unknown");

export function torSnapshotRows(snap) {
  if (!snap || typeof snap !== "object" || Array.isArray(snap)) return [];
  const boot = snap.bootstrap || {};
  const cons = snap.consensus || {};
  const guards = Object.entries(snap.guards || {});
  const circuits = Array.isArray(snap.circuits) ? snap.circuits : [];
  return [
    ["Control port", snap.control === "ok" ? "ok" : "unreachable"],
    ["Version", snap.version || "unknown"],
    [
      "Bootstrap",
      `${Number.isFinite(boot.progress) ? `${boot.progress}%` : "unknown"}${boot.tag ? ` (${boot.tag})` : ""}, last change ${when(boot.changed_at)}`,
    ],
    [
      "Consensus",
      `valid after ${when(cons.valid_after)}, valid until ${when(cons.valid_until)}, age ${age(cons.age_sec)} (source: ${cons.source || "none"})`,
    ],
    ["Guards", guards.length ? guards.map(([k, n]) => `${k} ${n}`).join(", ") : "none reported"],
    [
      "Circuits",
      circuits.length
        ? circuits.map((c) => `${c.state} ${c.purpose} ${c.count}`).join(", ")
        : "none reported",
    ],
  ];
}

export function TorSnapshot({ snap }) {
  const rows = torSnapshotRows(snap);
  if (!rows.length) return null;
  return html`<section>
    <h3 class="card-subhead">Tor</h3>
    <div class="table-scroll"><table class="est-table">
      <tbody>
        ${rows.map(
          ([label, value]) => html`<tr>
            <td class=${label === "Control port" && value !== "ok" ? "status-bad" : "text-muted"}>${label}</td>
            <td>${value}</td>
          </tr>`,
        )}
      </tbody>
    </table></div>
  </section>`;
}
