import { html } from "../app/preact.mjs";
import { AdoptRigForm } from "../workers/workeradopt.mjs";
import { buildFields, detailSnapshot } from "../workers/workerlogic.mjs";
import { RigUpgrade, StatusLine } from "../workers/workerupgrade.mjs";
import { WorkerField, WorkerInspect } from "../workers/workerview.mjs";
import { rigDonation } from "./donation-model.mjs";
import { DonationControl } from "./machines-donation.mjs";
import { rigHealth, rigView } from "./machines-model.mjs";

export class RigInspector extends WorkerInspect {
  constructor(props) {
    super(props);
    this.state.chartRange = "24h";
  }

  componentDidUpdate(previous) {
    if (previous.shared > 1 && !(this.props.shared > 1) && this.state.phase === "ready") {
      this.load();
      return;
    }
    if (
      previous.worker !== this.props.worker &&
      this.state.phase === "ready" &&
      !this.state.busy &&
      !this.isDirty()
    )
      this.load(true);
  }

  async load(passive = false) {
    if (this.state.phase !== "ready") return super.load();
    try {
      const response = await fetch(
        `/api/worker?name=${encodeURIComponent(this.props.name)}&range=24h`,
      );
      if (!response.ok) throw new Error();
      const detail = await response.json();
      if (passive && (this.state.busy || this.isDirty())) return;
      this.setState({
        stale: false,
        detail,
        editText: JSON.stringify(detailSnapshot(detail), null, 2),
        tableEdits: {},
        jsonError: null,
      });
    } catch {
      this.setState({ stale: true });
    }
  }

  render() {
    const { phase, detail, error } = this.state;
    const { name, onClose } = this.props;
    const close = () => this.dialogRef.current?.close();
    return html`<dialog class="rig-inspector" ref=${this.dialogRef} aria-labelledby="rig-inspector-title"
      onClose=${onClose} onCancel=${(event) => (this.state.busy || this.isDirty()) && event.preventDefault()}>
      <div class="rig-inspector-header">
        <h2 id="rig-inspector-title" ref=${this.titleRef} tabindex="-1">${name}</h2>
        <button type="button" disabled=${this.state.busy} onClick=${close}>Close</button>
      </div>
      ${phase === "loading" ? html`<p role="status">Loading this rig…</p>` : null}
      ${phase === "error" ? html`<p role="alert">This rig could not be loaded: ${error}</p>` : null}
      ${phase === "ready" ? this.renderBody(detail) : null}
    </dialog>`;
  }

  renderBody(detail) {
    const row = rigView(this.props.worker);
    const health = rigHealth(detail);
    const version = detail.rigforge?.version;
    const latest = detail.rigforge_update?.latest;
    const shared = this.props.shared > 1;
    const donation = rigDonation(this.props.worker, shared ? null : detail.rig_config);
    return html`${
      shared
        ? html`<p role="note">${this.props.shared} rigs report the name ${this.props.name}. Status and shares are for the rig you opened; the rest is for the first rig the host lists with that name, so changes are off until each rig has its own name.</p>`
        : null
    }
      ${this.state.stale ? html`<p role="alert">This rig could not be refreshed, so the details below may be out of date.</p>` : null}
      <dl class="rig-health">
        <div><dt>Status</dt><dd>${row.status}${row.note ? ` · ${row.note}` : ""}</dd></div>
        <div><dt>Last seen mining</dt><dd>${health.lastSeen ? new Date(health.lastSeen).toLocaleString() : "Not recorded in the last 24 hours"}</dd></div>
        <div><dt>Software</dt><dd>${
          version
            ? `RigForge ${version}${latest ? ` · ${latest} available` : " · latest"}`
            : "Not reported: this rig does not publish a RigForge version"
        }</dd></div>
        <div><dt>24 h hashrate</dt><dd>${health.average ? `${health.average} average` : "Unavailable"}</dd></div>
        <div><dt>Accepted shares</dt><dd>${row.accepted ?? "Unavailable"}</dd></div>
        <div><dt>Rejected shares</dt><dd>${row.rejected ?? "Unavailable"}</dd></div>
        <div><dt>XMRig developers</dt><dd>${donation.text}${donation.mismatch ? ` · ${donation.mismatch}` : ""}</dd></div>
      </dl>
      <details class="rig-advanced">
        <summary>Advanced</summary>
        ${this.renderAdvanced(detail)}
      </details>`;
  }

  renderAdvanced(detail) {
    if (!detail.control_enabled)
      return html`<p>Rig control is off. Turn on the editor in Settings to update, adopt or configure rigs.</p>`;
    const blocked =
      this.props.shared > 1
        ? "Give each rig its own name to update, adopt or configure it from here."
        : !this.props.writable
          ? "Rig changes are unavailable while disconnected or signed out."
          : null;
    if (blocked && !this.isDirty()) return html`<p>${blocked}</p>`;
    if (!detail.editable)
      return html`<h3>Manage this rig</h3>
        <p>Managing is separate from mining: this rig keeps mining either way. After you apply, the form confirms the saved entry; managed telemetry appears after the next poll of the rig.</p>
        <${AdoptRigForm} name=${this.props.name} ip=${detail.ip} onAdopted=${() => this.load()} />`;
    const { mode, tableEdits, editText, jsonError, busy, result } = this.state;
    return html`<h3>Update this rig</h3>
      ${
        detail.rigforge_update?.available && !detail.rigforge_update.url
          ? html`<p>RigForge ${detail.rigforge_update.latest} is available, but its release page is not reported, so it cannot be offered here.</p>`
          : detail.rigforge_update?.available
            ? html`<${RigUpgrade} name=${this.props.name} update=${detail.rigforge_update}
            canEdit=${!blocked} busy=${busy} onDone=${() => this.load()} />`
            : html`<p>This rig is on the latest release it reports.</p>`
      }
      <${DonationControl} name=${this.props.name} worker=${this.props.worker} rigConfig=${detail.rig_config}
        earnings=${this.props.earnings} canEdit=${!blocked && !busy} onDone=${() => this.load()} />
      <h3>Configuration</h3>
      <div role="group" aria-label="Configuration view">
        <button type="button" aria-pressed=${mode === "table"} onClick=${() => this.setMode("table")}>Table</button>
        <button type="button" aria-pressed=${mode === "json"} onClick=${() => this.setMode("json")}>JSON</button>
      </div>
      ${
        mode === "table"
          ? buildFields(detail.writable_keys, detail.last_applied, detail.rig_config).map(
              (field) => html`<${WorkerField} field=${field} edits=${tableEdits} busy=${busy}
              onEdit=${(key, value) => this.setState({ tableEdits: { ...tableEdits, [key]: value } })} />`,
            )
          : html`<label>Rig configuration JSON
            <textarea class="rig-json" spellcheck="false" rows="10" disabled=${busy}
              value=${editText} onInput=${(event) => this.onJsonInput(event.target.value)}></textarea></label>
            ${jsonError ? html`<p role="alert">${jsonError}</p>` : null}
            <label>Load from file <input type="file" accept="application/json,.json" disabled=${busy}
              onChange=${(event) => this.onFilePick(event)} /></label>`
      }
      <button type="button" disabled=${busy || !!blocked} onClick=${() => this.apply()}>${busy ? "Applying…" : "Apply to rig"}</button>
      ${!busy && !blocked && this.isDirty() ? html`<p>Unsaved: apply before closing, or the change is lost.</p>` : null}
      ${blocked ? html`<p role="alert">${blocked}</p>` : null}
      <${StatusLine} result=${result} />`;
  }
}
