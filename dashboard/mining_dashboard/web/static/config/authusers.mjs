import { Component, html } from "../app/preact.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
export const validPassword = (password) => {
  const bytes = new TextEncoder().encode(password).length;
  return [...password].length >= 8 && bytes <= 72 && !password.includes("\0");
};

export class AuthUsersEditor extends Component {
  constructor(props) {
    super(props);
    this.state = { passwords: {}, metricsPassword: "", standbyPassword: "", busy: null, error: "" };
  }
  change(index, key, value) {
    const users = this.props.users.map((user, at) =>
      at === index ? { ...user, [key]: value } : user,
    );
    this.props.onChange(users);
  }
  async resetPassword(index) {
    const password = this.state.passwords[index] || "";
    if (!validPassword(password)) return;
    const account = this.props.users[index];
    this.setState({ busy: index, error: "" });
    try {
      const response = await fetch("/api/auth/hash", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ password }),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const { password_hash: passwordHash } = await response.json();
      if (!passwordHash) throw new Error("Password hash was not returned");
      if (this.props.users[index] !== account) {
        this.setState({ busy: null, error: "Account changed while hashing; try again." });
        return;
      }
      this.change(index, "password_hash", passwordHash);
      this.setState({ passwords: { ...this.state.passwords, [index]: "" }, busy: null });
    } catch (error) {
      this.setState({ busy: null, error: `Could not prepare password: ${error}` });
    }
  }
  async setMetricsPassword() {
    const password = this.state.metricsPassword;
    if (!validPassword(password)) return;
    this.setState({ busy: "metrics", error: "" });
    try {
      const response = await fetch("/api/auth/hash", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ password }),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const { password_hash: passwordHash } = await response.json();
      if (!passwordHash) throw new Error("Password hash was not returned");
      this.props.onMetricsChange(passwordHash);
      this.setState({ metricsPassword: "", busy: null });
    } catch (error) {
      this.setState({ busy: null, error: `Could not prepare password: ${error}` });
    }
  }
  async setStandbyPassword() {
    const password = this.state.standbyPassword;
    if (!validPassword(password)) return;
    this.setState({ busy: "standby", error: "" });
    try {
      const response = await fetch("/api/auth/hash", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ password }),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const { password_hash: passwordHash } = await response.json();
      if (!passwordHash) throw new Error("Password hash was not returned");
      this.props.onStandbyChange(passwordHash);
      this.setState({ standbyPassword: "", busy: null });
    } catch (error) {
      this.setState({ busy: null, error: `Could not prepare password: ${error}` });
    }
  }
  render({ users, onChange, metricsHash, standbyHash }) {
    return html`<section class="card auth-users" aria-labelledby="auth-users-title">
      <h2 id="auth-users-title">Dashboard accounts</h2>
        <p class="text-muted">Add administrators and read-only viewers. The upgraded owner account remains an administrator and keeps the console recovery password. New passwords are hashed before they enter the configuration draft.</p>
      ${users.map(
        (user, index) => html`<fieldset class="auth-user" key=${index}>
        <legend>Account ${index + 1}</legend>
        <label>Name <input value=${user.name || ""} autocomplete="off" disabled=${this.state.busy !== null} onInput=${(event) => this.change(index, "name", event.target.value)} /></label>
        <label>Role <select value=${user.role || "viewer"} disabled=${this.state.busy !== null} onChange=${(event) => this.change(index, "role", event.target.value)}>
          <option value="admin">Admin</option><option value="viewer">Read-only viewer</option>
        </select></label>
        <label>New password <input type="password" autocomplete="new-password"
          minlength="8" disabled=${this.state.busy !== null}
          value=${this.state.passwords[index] || ""}
          onInput=${(event) => this.setState({ passwords: { ...this.state.passwords, [index]: event.target.value } })} /></label>
        <span class="text-muted text-xs">At least 8 characters; at most 72 UTF-8 bytes</span>
        <div class="auth-user-actions">
          <button type="button" class="btn-toggle" disabled=${this.state.busy !== null || !validPassword(this.state.passwords[index] || "")}
            onClick=${() => this.resetPassword(index)}>${this.state.busy === index ? "Hashing…" : "Set password"}</button>
            <button type="button" class="btn-toggle" disabled=${this.state.busy !== null}
              onClick=${() => onChange(users.filter((_, at) => at !== index))}>Remove</button>
        </div>
      </fieldset>`,
      )}
        <button type="button" class="btn-toggle" disabled=${this.state.busy !== null} onClick=${() => onChange([...users, { name: "", role: "viewer", password_hash: "" }])}>Add account</button>
        <fieldset class="auth-user metrics-user">
          <legend>Monitoring credential</legend>
          <p class="text-muted">Use the fixed username <code>metrics</code> with Prometheus or Grafana. This credential cannot open the dashboard.</p>
          <label>Monitoring password <input type="password" autocomplete="new-password"
            minlength="8"
            placeholder=${metricsHash ? "set — enter a new password to replace" : "not set"}
            value=${this.state.metricsPassword}
            onInput=${(event) => this.setState({ metricsPassword: event.target.value })} /></label>
          <span class="text-muted text-xs">At least 8 characters; at most 72 UTF-8 bytes</span>
          <div class="auth-user-actions"><button type="button" class="btn-toggle"
            disabled=${this.state.busy !== null || !validPassword(this.state.metricsPassword)}
            onClick=${() => this.setMetricsPassword()}>${this.state.busy === "metrics" ? "Hashing…" : "Set monitoring password"}</button></div>
        </fieldset>
        <fieldset class="auth-user standby-user">
          <legend>XvB standby credential</legend>
          <p class="text-muted">Use the fixed username <code>standby</code> for the XvB standby feed. This credential cannot open the dashboard.</p>
          <label>Standby password <input type="password" autocomplete="new-password"
            minlength="8"
            placeholder=${standbyHash ? "set — enter a new password to replace" : "not set"}
            value=${this.state.standbyPassword}
            onInput=${(event) => this.setState({ standbyPassword: event.target.value })} /></label>
          <span class="text-muted text-xs">At least 8 characters; at most 72 UTF-8 bytes</span>
          <div class="auth-user-actions"><button type="button" class="btn-toggle"
            disabled=${this.state.busy !== null || !validPassword(this.state.standbyPassword)}
            onClick=${() => this.setStandbyPassword()}>${this.state.busy === "standby" ? "Hashing…" : "Set standby password"}</button></div>
        </fieldset>
        ${this.state.error ? html`<p class="status-bad" role="alert">${this.state.error}</p>` : null}
    </section>`;
  }
}
