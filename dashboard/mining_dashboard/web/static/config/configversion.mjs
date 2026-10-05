import { html } from "../app/preact.mjs";

export const ConfigVersion = ({ cfg }) => html`<div class="card">
    <p class="text-muted">Config file version ${typeof cfg?.config_version === "string" ? cfg.config_version : "unknown"}</p>
    ${cfg?._config_version_newer ? html`<p class="status-warn">This configuration was written by a newer Pithead version. Saving is blocked while it contains settings this version does not know. Update the OS before saving.</p>` : null}
</div>`;
