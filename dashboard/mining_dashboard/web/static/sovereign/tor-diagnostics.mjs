import { Component, html } from "../app/preact.mjs";
import { runDiag } from "../system/diagview.mjs";

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

export class TorDiagnostics extends Component {
  state = { phase: "idle", snap: null, error: "" };
  check = async () => {
    this.setState({ phase: "running", snap: null, error: "" });
    try {
      const result = await runDiag("diag-doctor", {}, "the Tor check");
      this.setState({ phase: "done", snap: result.tor ?? null });
    } catch (error) {
      this.setState({ phase: "failed", error: String(error?.message || error) });
    }
  };
  render() {
    const { phase, snap, error } = this.state;
    const rows = torSnapshotRows(snap);
    return html`<div class="tor-diagnostics">
      <button type="button" disabled=${phase === "running"} onClick=${() => this.check()}>
        ${phase === "running" ? "Checking…" : "Check Tor now"}
      </button>
      ${phase === "failed" ? html`<p class="lan-verdict lan-fail" role="alert">${error}</p>` : null}
      ${
        phase === "done" && !rows.length
          ? html`<p class="muted" role="status">The host returned no Tor snapshot.</p>`
          : null
      }
      ${
        rows.length
          ? html`<dl class="tor-snapshot">
            ${rows.map(
              ([label, value]) => html`<dt>${label}</dt>
                <dd class=${label === "Control port" && value !== "ok" ? "lan-verdict lan-fail" : ""}>
                  ${value}
                </dd>`,
            )}
          </dl>`
          : null
      }
    </div>`;
  }
}
