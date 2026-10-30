import { Modal } from "../app/modal.mjs";
import { html } from "../app/preact.mjs";
import { pathGet } from "../config/configsync.mjs";
import { ConfigView, PreviewModal } from "../config/configview.mjs";

export const EARNINGS_FIELDS = {
  xvb: { key: "xvb.enabled", label: "Join the XvB bonus", type: "boolean" },
  electricity: {
    key: "dashboard.energy.cost_per_kwh",
    label: "Electricity price",
    type: "number",
  },
};

export function electricityError(raw) {
  return String(raw).trim() !== "" && Number.isFinite(Number(raw)) && Number(raw) >= 0
    ? null
    : "Enter a finite electricity price of zero or more per kWh; zero leaves power cost unset.";
}

export class EarningsControl extends ConfigView {
  constructor(props) {
    super(props);
    this.state.phase = "idle";
  }
  componentDidMount() {}
  async load() {
    this.setState({ phase: "loading", error: null });
    await super.load();
  }
  componentWillUnmount() {
    this.props.onDirtyChange?.(false);
  }
  async save() {
    if (!this.props.enabled || this.invalid() || !this.editable()) return;
    await super.save();
  }
  async commit() {
    if (!this.props.enabled) return;
    await super.commit();
  }
  editable() {
    return ["editableKeys", "confirmKeys", "approvalKeys"].some((key) =>
      this.state[key].includes(EARNINGS_FIELDS[this.props.kind].key),
    );
  }
  invalid() {
    const field = EARNINGS_FIELDS[this.props.kind];
    return field.type === "number"
      ? electricityError(
          this.state.drafts[field.key] ?? pathGet(this.state.candidate, field.key) ?? "",
        )
      : null;
  }
  dismiss() {
    this.modalRef.current?.close();
  }
  render() {
    if (!this.props.enabled) return null;
    const field = EARNINGS_FIELDS[this.props.kind];
    const { phase, candidate, preview, error, result, confirmText, payoutSuffixes } = this.state;
    const busy = ["loading", "previewing", "committing"].includes(phase);
    const close = () =>
      this.setState({
        phase: "idle",
        preview: null,
        candidate: null,
        editText: "",
        pristine: "",
        error: null,
      });
    const changed = this.state.editText !== this.state.pristine;
    const onEdit = (value) => this.onFieldEdit(field, value);
    const raw = this.state.drafts[field.key] ?? pathGet(candidate, field.key) ?? "";
    const invalid = phase === "form" ? this.invalid() : null;
    const review = ["confirm", "committing"].includes(phase);
    return html`<div class="earnings-control">
      <button type="button" disabled=${busy} onClick=${() => this.load()}>${field.label}</button>
      ${
        phase === "idle"
          ? null
          : review
            ? html`<${PreviewModal} modalRef=${this.modalRef} preview=${preview}
        confirmText=${confirmText} onConfirmText=${(value) => this.setState({ confirmText: value })}
        payoutSuffixes=${payoutSuffixes} onPayoutSuffix=${(chain, value) => this.setState({ payoutSuffixes: { ...payoutSuffixes, [chain]: value } })}
        onConfirm=${() => this.commit()} onCancel=${() => this.dismiss()} onClose=${close} busy=${phase === "committing"} />`
            : html`<${Modal} ref=${this.modalRef} title=${field.label} onCancel=${() => !busy && this.dismiss()} onClose=${close}>
          ${phase === "loading" ? html`<p role="status">Loading the host's current settings…</p>` : null}
          ${phase === "disabled" ? html`<p>Settings are unavailable on this host.</p>` : null}
          ${error ? html`<p role="alert">${typeof error === "string" ? error : "The host rejected this change. Review the configuration before trying again."}</p>` : null}
          ${
            candidate && ["form", "previewing"].includes(phase)
              ? html`
            <label>${
              field.type === "boolean"
                ? html`<input type="checkbox" checked=${pathGet(candidate, field.key) === true}
              disabled=${busy || !this.editable()} onChange=${(event) => onEdit(event.target.checked)} /> Join the XvB bonus`
                : html`Electricity price (${candidate.dashboard?.energy?.currency || "currency not reported"} per kWh)
                <input type="text" inputmode="decimal" value=${raw} disabled=${busy || !this.editable()}
                aria-invalid=${!!invalid} aria-describedby="electricity-validation" onInput=${(event) => onEdit(event.target.value)} />`
            }</label>
            ${field.type === "boolean" ? html`<p>XvB routes part of your hashrate to its bonus raffle; wins and payouts are not guaranteed. This is the host's current setting.</p>` : html`<p id="electricity-validation" role=${invalid ? "alert" : null}>${invalid || "Zero leaves power cost unset. The host validates the price before saving."}</p>`}
            ${!this.editable() ? html`<p>The host does not permit this setting to be changed here.</p>` : null}
            <button type="button" disabled=${busy || !changed || !!invalid || !this.editable()} onClick=${() => this.save()}>${phase === "previewing" ? "Preparing review…" : "Review changes"}</button>`
              : null
          }
          ${phase === "done" ? html`<p role="status">${result?.status === "applied" ? "Changes applied." : "The change was not applied. Its host result remains available in Settings."}</p>` : null}
          <button type="button" disabled=${busy} onClick=${() => this.dismiss()}>Close</button>
        </${Modal}>`
      }
    </div>`;
  }
}
