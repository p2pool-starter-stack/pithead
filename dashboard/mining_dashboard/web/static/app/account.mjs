import { html } from "./preact.mjs";

export function Account({ auth, compact = false }) {
  if (!auth?.enabled) return null;
  const label = auth.role === "viewer" ? "Read-only" : "Admin";
  return html`<div class=${compact ? "account account-compact" : "account"}>
    <span class="account-user"><strong>${auth.user}</strong><span class="badge badge-outline">${label}</span></span>
    <form method="post" action="/logout"><button type="submit" class="btn-toggle">Sign out</button></form>
  </div>`;
}
