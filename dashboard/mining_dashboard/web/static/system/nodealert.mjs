import { html } from "../app/preact.mjs";

export const NodeAlertBanner = ({ alert }) =>
  alert
    ? html`<div class="disconnected-banner" id="node-alert" role="alert">
        <strong>${alert.title}</strong>
        ${[...alert.reasons, ...alert.heal].map((line) => html`<div>${line}</div>`)}
      </div>`
    : null;
