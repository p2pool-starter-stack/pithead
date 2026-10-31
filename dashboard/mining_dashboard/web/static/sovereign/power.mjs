import { Component, html } from "../app/preact.mjs";
import { pollOsResult } from "../system/osupdate.mjs";

export async function powerAction(action) {
  const response = await fetch("/api/control/power", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Pithead-Control": "1" },
    body: JSON.stringify({ action }),
  });
  if (response.status !== 202) throw new Error(`Power request failed (HTTP ${response.status}).`);
  const { id } = await response.json();
  if (!id) throw new Error("Power request returned no receipt.");
  return id;
}

export class PowerControl extends Component {
  constructor(props) {
    super(props);
    this.state = { action: "", confirmation: "", phase: "idle", error: "" };
    this.stopped = false;
  }

  componentWillUnmount() {
    this.stopped = true;
  }

  async order() {
    const { action, confirmation } = this.state;
    if (
      !this.props.snapshot?.os_update ||
      !this.props.snapshot?.control_enabled ||
      confirmation !== action.toUpperCase() ||
      this.state.phase !== "confirm"
    )
      return;
    this.setState({ phase: "submitting", error: "" });
    let id;
    try {
      id = await powerAction(action);
    } catch (error) {
      this.setState({ phase: "error", error: error.message });
      return;
    }
    const result = await pollOsResult(id, null, 30).catch(() => null);
    if (result && !["rebooting", "shutting-down"].includes(result.status)) {
      this.setState({ phase: "error", error: result.error || "The power request was refused." });
      return;
    }
    this.setState({ phase: action === "reboot" ? "rebooting" : "powering-off" });
    if (action === "reboot") await this.reconnect();
  }

  async reconnect() {
    for (let attempt = 0; attempt < 300 && !this.stopped; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 2000));
      if (this.stopped) return;
      try {
        const response = await fetch("/api/state", { cache: "no-store" });
        if (response.ok) {
          window.location.reload();
          return;
        }
      } catch {}
    }
    if (!this.stopped)
      this.setState({
        phase: "error",
        error: "The dashboard has not returned. Check the appliance before trying again.",
      });
  }

  render({ snapshot }) {
    if (!snapshot?.os_update || !snapshot?.control_enabled) return null;
    const { action, confirmation, phase, error } = this.state;
    const choose = (next) =>
      this.setState({ action: next, confirmation: "", phase: "confirm", error: "" });
    return html`<section aria-label="Appliance power">
      <h4>Appliance power</h4>
      ${
        phase === "idle"
          ? html`
        <button type="button" onClick=${() => choose("reboot")}>Reboot</button>
        <button type="button" onClick=${() => choose("poweroff")}>Power off</button>`
          : null
      }
      ${
        phase === "confirm"
          ? html`
        <p>${action === "reboot" ? "Mining pauses while the appliance restarts. This page reconnects when the dashboard returns." : "Mining stops and the dashboard will not return. Press the physical power button to start the appliance again."}</p>
        <label>Type ${action.toUpperCase()} to confirm
          <input value=${confirmation} autoComplete="off" onInput=${(event) => this.setState({ confirmation: event.target.value })} /></label>
        <button type="button" disabled=${confirmation !== action.toUpperCase()} onClick=${() => this.order()}>${action === "reboot" ? "Reboot now" : "Power off now"}</button>
        <button type="button" onClick=${() => this.setState({ phase: "idle", confirmation: "" })}>Cancel</button>`
          : null
      }
      <div role="status" aria-live="polite">
        ${phase === "submitting" ? "Sending power request…" : null}
        ${phase === "rebooting" ? "Rebooting. Leave this page open to reconnect." : null}
        ${phase === "powering-off" ? "Power-off requested. This page will not reconnect. Press the physical power button to start the appliance again." : null}
      </div>
      ${phase === "error" ? html`<p role="alert">${error}</p><button type="button" onClick=${() => this.setState({ phase: "idle" })}>Back</button>` : null}
    </section>`;
  }
}
