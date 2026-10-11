// A single Configuration form field (#33). Numeric text is held by the view as a draft (#3350),
// so this component renders whatever `value` it is handed and only flags `invalid`.
import { html } from "../app/preact.mjs";
import { SECRET_HINT } from "./configlogic.mjs";
import { coerceForType } from "./configsync.mjs";

export const validNumber = (raw) => Number.isFinite(coerceForType("number", raw));

const HOST_ONLY_TITLE = "Host-only — edit config.json and run ./pithead apply";
// #719: an in-scope confirm-gated field IS editable, but committing it is disruptive — the review modal makes you type APPLY. The tooltip sets that expectation up front.
const CONFIRM_TITLE = "Editable — this change is disruptive; you'll type APPLY to confirm at Save";
const APPROVAL_TITLE = "Editable — this sensitive change is recorded under your signed-in identity";
// `full` (#529): the pinned Core card mixes fields from several sections, so its rows need the
// FULL dotted key ("monero.wallet_address") to stay unambiguous. A natural section keeps the
// shorter relative label ONLY while all its fields share one top-level key (its heading then says
// the rest); a logical section that mixes top-level keys (#611 — Wallets & payout spans monero.*
// AND tari.*) gets full keys too, or monero.view_key and tari.view_key would both render as a
// bare "view_key" (and System / advanced would show four identical "data_dir" rows).
//
// A host-only field has no event listener; it cannot enter staged edits.
export const Field = ({ field, value, onEdit, full, invalid }) => {
  // The host derives this public key from the dual address; ask only for the private view key.
  if (field.key === "tari.spend_public_key") return null;
  const editable = field.editable !== false;
  const label = full ? field.key : field.path.slice(1).join(".") || field.path[0];
  const title = !editable
    ? HOST_ONLY_TITLE
    : field.confirm
      ? CONFIRM_TITLE
      : field.approval
        ? APPROVAL_TITLE
        : undefined;
  const change = editable ? (e) => onEdit(field, e.target.value) : undefined;
  let input;
  if (field.type === "boolean") {
    input = html`<select value=${String(value)} disabled=${!editable} onChange=${change}>
        <option value="true">true</option>
        <option value="false">false</option>
    </select>`;
  } else if (field.type === "select") {
    input = html`<select value=${value} disabled=${!editable} onChange=${change}>
        ${field.options.map((o) => html`<option value=${o}>${o}</option>`)}
    </select>`;
  } else if (field.type === "secret") {
    input = html`<input type="password" value=${value} placeholder=${SECRET_HINT}
        disabled=${!editable} onInput=${change} />`;
  } else {
    input = html`<input type=${field.type === "number" ? "number" : "text"} value=${value}
        step=${field.type === "number" ? "any" : undefined}
        aria-invalid=${invalid ? "true" : undefined}
        aria-describedby=${invalid ? `${field.key}-invalid` : undefined}
        disabled=${!editable} onInput=${change} />`;
  }
  return html`<label class="config-field" title=${title}>
      <span class="config-field-name">${label}${field.defaulted ? " (default)" : ""}</span>
      ${input}
      ${invalid ? html`<span class="config-field-warning" role="alert" id=${`${field.key}-invalid`}>⚠ Not a valid number; the saved value is unchanged.</span>` : null}
      ${field.warning ? html`<span class="config-field-warning">⚠ ${field.warning}</span>` : null}
  </label>`;
};
