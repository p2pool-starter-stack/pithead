// Plain power control (#2384): reboot and clean poweroff, dispatched through the SAME control
// channel as everything else. The container only asks; the host writes the result BEFORE issuing
// the order (46b-control-power.sh), so this page always learns whether the order was accepted.
//
// Reboot reconnects like the OS-update reboot (osupdate.mjs) — the machine comes back on its own.
// Poweroff deliberately does NOT reconnect: the dashboard is not coming back, and an operator who
// waited for a reconnect that never arrives would assume the machine is bricked. Its confirm copy
// says plainly that only a hand at the physical power button brings it up again.

import { Component, html } from "../app/preact.mjs";
import { pollOsResult } from "./osupdate.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const POLL_MS = 2000;

// POST one power action; resolves to the intent id (the server always answers 202).
export async function powerAction(action) {
  const res = await fetch("/api/control/power", {
    method: "POST",
    headers: CONTROL_HEADERS,
    body: JSON.stringify({ action }),
  });
  if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
  return (await res.json()).id;
}

// Header control. Renders only when the appliance and the control channel are on (same gate as
// OsUpdateControl). phase: closed | menu | confirm-reboot | confirm-poweroff | rebooting |
// powering-off | powered-off | error.
export class PowerControl extends Component {
  constructor(props) {
    super(props);
    this.state = { phase: "closed", error: "", confirmText: "" };
  }

  fail(e) {
    this.setState({ phase: "error", error: String((e && e.message) || e) });
  }

  async reboot() {
    this.setState({ phase: "rebooting", error: "" });
    let id;
    try {
      id = await powerAction("reboot");
    } catch (e) {
      return this.fail(e);
    }
    const out = await pollOsResult(id, null, 30).catch(() => null); // reboot cuts the answer off
    if (out?.status === "rejected") return this.fail(out.error || "The reboot was refused.");
    this.reconnect();
  }

  async poweroff() {
    this.setState({ phase: "powering-off", error: "" });
    let id;
    try {
      id = await powerAction("poweroff");
    } catch (e) {
      return this.fail(e);
    }
    const out = await pollOsResult(id, null, 30).catch(() => null); // machine may be down
    if (out?.status === "rejected") return this.fail(out.error || "The power-off was refused.");
    this.setState({ phase: "powered-off" });
  }

  // The static "reconnecting" behaviour, same as OsUpdateControl's — reboot only.
  async reconnect(max = 300) {
    for (let i = 0; i < max; i++) {
      await new Promise((r) => setTimeout(r, POLL_MS));
      try {
        const res = await fetch("/api/state?range=1h");
        if (res.ok) {
          window.location.reload();
          return;
        }
      } catch {
        /* still rebooting */
      }
    }
  }

  renderBody() {
    const { phase, error, confirmText } = this.state;
    if (phase === "error")
      return html`<p class="status-bad">${error}</p>
          <div class="config-modal-actions">
              <button class="btn-toggle" onClick=${() => this.setState({ phase: "closed", error: "" })}>Close</button>
          </div>`;
    if (phase === "rebooting")
      return html`<p>Rebooting — this page reconnects when the dashboard returns.</p>
          <p class="text-muted">Leave it open. Mining pauses while the machine restarts.</p>`;
    if (phase === "powering-off") return html`<p>Powering off…</p>`;
    if (phase === "powered-off")
      return html`<p class="status-ok">The machine is powering off.</p>
          <p>This page will <strong>not</strong> reconnect on its own. Press the machine's
          physical power button to bring it back — mining resumes unaided once it boots.</p>
          <div class="config-modal-actions">
              <button class="btn-toggle" onClick=${() => this.setState({ phase: "closed" })}>Close</button>
          </div>`;
    if (phase === "confirm-reboot")
      return html`<p>Reboot the machine now. Mining pauses while it restarts — typically under
          five minutes — and the machine comes back on its own.</p>
          <label class="config-confirm-type">Type <code>REBOOT</code> to confirm:
              <input type="text" value=${confirmText}
                  onInput=${(e) => this.setState({ confirmText: e.target.value })} /></label>
          <div class="config-modal-actions">
              <button class="btn-toggle" onClick=${() => this.setState({ phase: "menu", confirmText: "" })}>Back</button>
              <button class="btn-toggle active" disabled=${confirmText !== "REBOOT"}
                  onClick=${() => this.reboot()}>Reboot now</button>
          </div>`;
    if (phase === "confirm-poweroff")
      return html`<p class="status-bad">This powers the machine off. Mining stops and the
          dashboard will <strong>not</strong> come back on its own — the machine restarts only
          when someone presses its physical power button.</p>
          <label class="config-confirm-type">Type <code>POWEROFF</code> to confirm:
              <input type="text" value=${confirmText}
                  onInput=${(e) => this.setState({ confirmText: e.target.value })} /></label>
          <div class="config-modal-actions">
              <button class="btn-toggle" onClick=${() => this.setState({ phase: "menu", confirmText: "" })}>Back</button>
              <button class="btn-toggle active" disabled=${confirmText !== "POWEROFF"}
                  onClick=${() => this.poweroff()}>Power off now</button>
          </div>`;
    // menu
    return html`<p>Reboot or power off this appliance.</p>
        <div class="config-modal-actions">
            <button class="btn-toggle" onClick=${() => this.setState({ phase: "closed" })}>Close</button>
            <button class="btn-toggle" onClick=${() => this.setState({ phase: "confirm-reboot", confirmText: "" })}>Reboot</button>
            <button class="btn-toggle" onClick=${() => this.setState({ phase: "confirm-poweroff", confirmText: "" })}>Power off</button>
        </div>`;
  }

  render() {
    const { enabled } = this.props;
    if (!enabled) return null;
    const { phase } = this.state;
    const open = phase !== "closed";
    return html`<button class="badge version-badge ml-2 badge-outline"
            title="Reboot or power off this appliance"
            onClick=${() => this.setState({ phase: open ? "closed" : "menu" })}>
            Power
        </button>${
          open
            ? html`<div class="config-modal-backdrop">
                <div class="card config-modal">
                    <h3>System power</h3>
                    ${this.renderBody()}
                </div>
            </div>`
            : null
        }`;
  }
}
