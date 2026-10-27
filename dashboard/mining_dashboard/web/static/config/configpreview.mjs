// Review and approval modal for one host-produced configuration preview (#1959).

import { Modal } from "../app/modal.mjs";
import { html } from "../app/preact.mjs";

export const PreviewModal = ({
  modalRef,
  preview,
  confirmText,
  onConfirmText,
  payoutSuffixes,
  onPayoutSuffix,
  onConfirm,
  onCancel,
  onClose,
  busy,
}) => {
  const changes = preview.changes || [];
  const payoutConfirmations = preview.payout_confirmations || {};
  const suffixesMatch = Object.entries(payoutConfirmations).every(
    ([chain, suffix]) => (payoutSuffixes?.[chain] || "") === suffix,
  );
  const displayValue = (key, value) =>
    String(value ?? (key === "workers.api_port" ? "8080 (default)" : "unset"));
  const armed = (!preview.destructive || confirmText === "APPLY") && suffixesMatch;
  return html`<${Modal} ref=${modalRef} title="Review changes" onClose=${onClose}
      onCancel=${() => !busy && onCancel()}>
          ${
            changes.length === 0
              ? html`<p class="text-muted">No configuration changes detected.</p>`
              : html`<ul class="config-preview-list">
                  ${changes.map((change) => {
                    const disruptive = change.flag === "DEST" || change.flag === "CONFIRM";
                    return html`<li class=${disruptive ? "config-preview-dest" : ""}>
                        ${disruptive ? "⚠ " : ""}${change.msg}</li>`;
                  })}
              </ul>`
          }
          ${(preview.preview_values || []).map(
            (value) => html`<p class="text-xs"><strong>${value.label}:</strong>
                <code>${displayValue(value.key, value.old)}</code> →
                <code>${displayValue(value.key, value.new)}</code></p>`,
          )}
          ${
            preview.approval_required
              ? html`<p class="status-warn">These settings are sensitive. Check the values above
                before continuing — the change and the dashboard user are recorded.</p>`
              : null
          }
          ${Object.entries(payoutConfirmations).map(
            ([chain, suffix]) => html`<label class="config-confirm-type">Type the final characters
                of the new ${chain === "monero" ? "Monero" : "Tari"} payout address,
                <code>${suffix}</code>:
                <input type="text" value=${payoutSuffixes?.[chain] || ""}
                       onInput=${(event) => onPayoutSuffix(chain, event.target.value)} /></label>`,
          )}
          ${
            preview.destructive
              ? html`<label class="config-confirm-type">Some changes above are disruptive.
                  Type <code>APPLY</code> to confirm:
                  <input type="text" value=${confirmText}
                         onInput=${(event) => onConfirmText(event.target.value)} /></label>`
              : null
          }
          ${
            busy
              ? html`<p class="text-muted text-xs">Applying — the host recreates the affected
                containers, including this dashboard, which briefly disconnects while it
                restarts. This page waits it out and shows the result; leave it open.</p>`
              : null
          }
          <div class="config-modal-actions">
              <button class="btn-toggle" onClick=${onCancel} disabled=${busy}>Cancel</button>
              <button class="btn-toggle active" onClick=${onConfirm}
                      disabled=${busy || changes.length === 0 || !armed}>
                  ${busy ? "Applying…" : "Confirm & apply"}
              </button>
          </div>
  </${Modal}>`;
};
