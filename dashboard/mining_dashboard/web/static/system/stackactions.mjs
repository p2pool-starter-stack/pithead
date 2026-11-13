import { Component, html } from "../app/preact.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };

export const RESTART_ALL_WORD = "RESTART";
export const RESTART_ALL_POLL_MS = 2000;
export const RESTART_ALL_POLL_MAX = 300;
export const TOR_RESET_POLL_MAX = 450;

export async function awaitRestartResult(id, { onOffline, onWaiting, pollMs, max } = {}) {
  for (let i = 0; i < (max ?? RESTART_ALL_POLL_MAX); i++) {
    await new Promise((resolve) => setTimeout(resolve, pollMs ?? RESTART_ALL_POLL_MS));
    let res;
    try {
      res = await fetch(`/api/control/result?id=${encodeURIComponent(id)}`);
    } catch {
      if (onOffline) onOffline();
      continue;
    }
    if (res.status === 202) {
      if (onWaiting) onWaiting();
      continue;
    }
    if ([502, 503, 504].includes(res.status)) {
      if (onOffline) onOffline();
      continue;
    }
    if (!res.ok) throw new Error(`Could not read the restart result: HTTP ${res.status}`);
    try {
      return await res.json();
    } catch {
      throw new Error("Could not read the restart result: the host returned an unreadable result.");
    }
  }
  return null;
}

export async function submitRestartAll(confirm) {
  let res;
  try {
    res = await fetch("/api/control/restart", {
      method: "POST",
      headers: CONTROL_HEADERS,
      body: JSON.stringify({ confirm }),
    });
  } catch {
    throw new Error(
      "Could not submit the restart: the dashboard could not reach the control service.",
    );
  }
  if (!res.ok && res.status !== 202)
    throw new Error(`Could not submit the restart: HTTP ${res.status}`);
  let id;
  try {
    ({ id } = await res.json());
  } catch {
    id = null;
  }
  if (typeof id !== "string" || !id)
    throw new Error("Could not submit the restart: the host returned no request id.");
  return id;
}

export class RestartAllControl extends Component {
  constructor(props) {
    super(props);
    this.state = { phase: "idle", text: "", message: "", offline: false };
  }

  async restart() {
    this.setState({ phase: "restarting", message: "", offline: false });
    try {
      const id = await submitRestartAll(RESTART_ALL_WORD);
      const result = await awaitRestartResult(id, {
        onOffline: () => this.setState({ offline: true }),
        onWaiting: () => this.setState({ offline: false }),
      });
      if (result === null) {
        this.setState({
          phase: "failed",
          message:
            "The stack has not answered within 10 minutes of the restart. Check the machine, then reload this page.",
        });
      } else if (result.status === "applied") {
        this.setState({ phase: "done", message: "The stack restarted." });
        (this.props.reload || (() => window.location.reload()))();
      } else {
        this.setState({
          phase: "failed",
          message: result.error || result.note || "The host did not restart the stack.",
        });
      }
    } catch (error) {
      this.setState({ phase: "failed", message: String(error.message || error) });
    }
  }

  render() {
    const { phase, text, message, offline } = this.state;
    const busy = phase === "restarting";
    return html`<section class="restart-all">
      <button class="btn-toggle" disabled=${busy} onClick=${() => this.setState({ phase: "confirming", text: "" })}>
        Restart all
      </button>
      ${
        phase === "confirming"
          ? html`<div class="restart-all-confirm">
          <p>Restart the whole stack. Mining stops briefly, this dashboard goes offline and comes
          back on its own, and the machine itself is not rebooted.</p>
          <label class="config-confirm-type">Type <code>${RESTART_ALL_WORD}</code> to confirm:
            <input type="text" value=${text}
                   onInput=${(event) => this.setState({ text: event.target.value })} /></label>
          <div class="config-modal-actions">
            <button class="btn-toggle" onClick=${() => this.setState({ phase: "idle" })}>Cancel</button>
            <button class="btn-toggle active" disabled=${text !== RESTART_ALL_WORD}
                    onClick=${() => this.restart()}>Restart the stack</button>
          </div>
        </div>`
          : null
      }
      ${
        busy
          ? html`<p class="text-muted">${
              offline
                ? "The dashboard is offline while the stack restarts. This page reloads when it is back…"
                : "Waiting for the host to restart the stack…"
            }</p>`
          : null
      }
      ${phase === "done" ? html`<p class="status-ok">${message}</p>` : null}
      ${phase === "failed" ? html`<p class="status-bad">${message}</p>` : null}
    </section>`;
  }
}

export class TorResetControl extends Component {
  constructor(props) {
    super(props);
    this.state = { phase: "idle", message: "" };
  }

  async reset() {
    this.setState({ phase: "running", message: "" });
    try {
      const result = await this.props.run(
        "tor-reset",
        {},
        "the Tor state reset",
        TOR_RESET_POLL_MAX,
      );
      if (result.status === "applied") {
        this.setState({
          phase: "done",
          message: "Tor state was reset, Tor restarted and monerod re-dialled through it.",
        });
      } else {
        this.setState({
          phase: "refused",
          message: result.error || result.note || "The host did not reset the Tor state.",
        });
      }
    } catch (error) {
      this.setState({ phase: "refused", message: String(error.message || error) });
    }
  }

  render() {
    const { phase, message } = this.state;
    return html`<div class="tor-reset">
      <button class="btn-toggle" disabled=${phase === "running"}
              onClick=${() => this.setState({ phase: "confirming" })}>Reset Tor state</button>
      ${
        phase === "confirming"
          ? html`<div class="tor-reset-confirm">
          <p>This discards Tor's circuit history: the saved state file is moved aside as a backup,
          Tor restarts and every Tor circuit rebuilds, and monerod re-dials its peers. Onion
          addresses are kept.</p>
          <p>The host can refuse. It resets only when the history is saturated and Tor or monerod
          is stalled, Tor auto-heal is on, no other host operation is running, and the cooldown has
          passed; the reason is shown here.</p>
          <div class="config-modal-actions">
            <button class="btn-toggle" onClick=${() => this.setState({ phase: "idle" })}>Cancel</button>
            <button class="btn-toggle active" onClick=${() => this.reset()}>Reset Tor state</button>
          </div>
        </div>`
          : null
      }
      ${
        phase === "running"
          ? html`<p class="text-muted">Waiting for the host to reset the Tor state — this can take several minutes…</p>`
          : null
      }
      ${phase === "done" ? html`<p class="status-ok">${message}</p>` : null}
      ${phase === "refused" ? html`<p class="status-bad">${message}</p>` : null}
    </div>`;
  }
}
