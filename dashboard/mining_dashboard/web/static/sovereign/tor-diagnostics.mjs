import { Component, html } from "../app/preact.mjs";
import { runDiag } from "../system/diagview.mjs";
import { torSnapshotRows } from "../system/torsnapshot.mjs";

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

export { torSnapshotRows };
