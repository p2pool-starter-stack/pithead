import { html } from "../app/preact.mjs";
import { AuthUsersEditor } from "./authusers.mjs";
import { pathGet, pathSet } from "./configsync.mjs";

export function AuthConfigEditor({ candidate, onChange }) {
  const users = pathGet(candidate, "dashboard.auth.users");
  if (!Array.isArray(users)) return null;
  const change = (path, value) => {
    pathSet(candidate, path, value);
    onChange(candidate);
  };
  return html`<${AuthUsersEditor} users=${users}
    metricsHash=${pathGet(candidate, "dashboard.auth.metrics_password_hash")}
    standbyHash=${pathGet(candidate, "dashboard.auth.standby_password_hash")}
    onChange=${(next) => change("dashboard.auth.users", next)}
    onMetricsChange=${(hash) => change("dashboard.auth.metrics_password_hash", hash)}
    onStandbyChange=${(hash) => change("dashboard.auth.standby_password_hash", hash)} />`;
}
