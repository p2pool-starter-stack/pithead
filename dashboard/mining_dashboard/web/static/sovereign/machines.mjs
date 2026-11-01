import { Component, html } from "../app/preact.mjs";
import { EarningsControl } from "./earnings-control.mjs";
import { RigInspector } from "./machines-inspector.mjs";
import {
  findRig,
  localMinerAvailable,
  rigRows,
  rigSettings,
  rigSummary,
  SORTS,
} from "./machines-model.mjs";

export class ConnectCard extends Component {
  state = { connection: null, status: "" };
  async componentDidMount() {
    try {
      const response = await (this.props.fetchFn || fetch)("/api/miner-connection", {
        cache: "no-store",
      });
      if (!response.ok) throw new Error();
      this.setState({ connection: await response.json() });
    } catch {
      this.setState({ status: "Connection details are unavailable. Reload to try again." });
    }
  }
  async copy() {
    try {
      await navigator.clipboard.writeText(rigSettings(this.state.connection));
      this.setState({ status: "Rig settings copied." });
    } catch {
      this.setState({
        status: "Copy is unavailable in this browser. Select the settings above and copy them.",
      });
    }
  }
  render({ writable = true }, { connection, status }) {
    return html`<section class="panel" aria-labelledby="connect-title"><h2 id="connect-title">Connect a miner</h2>
      ${
        connection?.url
          ? html`<dl class="connect-facts">
          <div><dt>Pool address</dt><dd><code>${connection.url}</code></dd></div>
          <div><dt>Rig password</dt><dd>${!connection.password_set ? "None set" : writable && connection.password ? html`<code>${connection.password}</code>` : "Hidden until you sign in again"}</dd></div>
          ${
            connection.tls
              ? html`<div><dt>TLS</dt><dd>On: turn on TLS in the miner and pin this certificate fingerprint</dd></div>
            <div><dt>Certificate fingerprint</dt><dd><code>${connection.fingerprint || "Unavailable: apply the configuration again"}</code></dd></div>`
              : null
          }
        </dl>
        ${connection.local_only ? html`<p>The pool listens on this machine only, so rigs on other machines cannot connect.</p>` : null}
        ${writable || !connection.password_set ? html`<button type="button" onClick=${() => this.copy()}>Copy rig settings</button>` : null}`
          : status
            ? null
            : html`<p role="status">Loading connection details…</p>`
      }
      <p role="status">${status}</p>
    </section>`;
  }
}

export class MachinesPage extends Component {
  state = { find: "", sort: "attention", shares: false, inspect: null };
  close() {
    const opener = this.opener;
    this.setState({ inspect: null });
    opener?.focus();
  }
  render(
    { state, connected = true, sessionExpired = false, onDirtyChange, fetchFn },
    { find, sort, shares, inspect },
  ) {
    if (!state) return html`<p class="panel" role="status">Waiting for rig data…</p>`;
    const workers = Array.isArray(state.workers) ? state.workers : [];
    const rows = rigRows(workers, { find, sort });
    const writable = connected && !sessionExpired;
    return html`<div class="machines-page">
      <${ConnectCard} fetchFn=${fetchFn} writable=${!sessionExpired} />
      ${
        localMinerAvailable(state) && writable
          ? html`<section class="panel" aria-labelledby="local-miner-title"><h2 id="local-miner-title">This box</h2>
          <${EarningsControl} kind="local-miner" enabled=${true} onDirtyChange=${(dirty) => onDirtyChange?.("local-miner", dirty)} />
        </section>`
          : null
      }
      <section class="panel" aria-labelledby="rigs-title"><h2 id="rigs-title">Rigs</h2>
        <p>${workers.length ? rigSummary(workers) : "No rigs have connected yet. Copy the rig settings above into your miner and it appears here."}</p>
        ${
          workers.length
            ? html`<details class="list-advanced"><summary>Advanced</summary>
          <label>Find a rig <input type="search" value=${find} onInput=${(event) => this.setState({ find: event.target.value })} /></label>
          <label>Sort by <select value=${sort} onChange=${(event) => this.setState({ sort: event.target.value })}>
            ${Object.entries(SORTS).map(([key, label]) => html`<option value=${key}>${label}</option>`)}
          </select></label>
          <label><input type="checkbox" checked=${shares} onChange=${(event) => this.setState({ shares: event.target.checked })} /> Show shares and version</label>
          <p role="status">${find ? `${rows.length} of ${workers.length} rigs match.` : ""}</p>
        </details>
        <ul class="rig-list">${rows.map(
          (
            row,
          ) => html`<li key=${`${row.index}:${row.name}`}><button type="button" class=${`rig-row${row.attention ? " rig-attention" : ""}`}
            onClick=${(event) => {
              this.opener = event.currentTarget;
              this.setState({ inspect: { ...row, worker: workers[row.index] } });
            }}>
            <span class="rig-name">${row.name}</span>
            <span class="rig-status">${row.status}${row.note ? html` <span class="rig-note">${row.note}</span>` : null}</span>
            <span class="rig-rate">${row.hashrate}</span>
            ${shares ? html`<span class="rig-extra">Accepted ${row.accepted ?? "unavailable"} · rejected ${row.rejected ?? "unavailable"} · ${row.version ? `RigForge ${row.version}` : "version not reported"}</span>` : null}
          </button></li>`,
        )}</ul>`
            : null
        }
      </section>
      ${
        inspect
          ? html`<${RigInspector} name=${inspect.name} writable=${writable}
            worker=${findRig(workers, inspect.name, inspect.occurrence) || inspect.worker} onClose=${() => this.close()} />`
          : null
      }
    </div>`;
  }
}
