// Click-to-adopt (#893): the form shown in Worker Inspect for a rig that isn't yet a write
// target. Prefilled with the worker's OBSERVED IP (proxy-reported — a #122 miner-advertised value,
// so it's a PREFILL only; the operator confirms or edits it before anything is sent), a default
// control port, and a token the operator must type. Submitting rides the SAME control-channel
// config path (GET /api/config -> POST preview -> POST commit) the Configuration view uses for any
// other edit — no new write endpoint. The host's own add-only gate (pithead's control_approval_gate)
// is what actually authorizes appending a brand-new workers.list[] descriptor; this only builds and
// sends the proposal.
//
// The worker reader reopens the directory-mounted config and credential map on every probe, so an
// applied append becomes visible on the next worker poll without restarting the dashboard.

import { Component, html } from "../app/preact.mjs";
import { pollResult } from "../config/configview.mjs";
import {
  buildAdoptedConfig,
  DEFAULT_API_PORT,
  DEFAULT_CONTROL_PORT,
  hostIsInternal,
  validateAdoptFields,
} from "./workeradoptlogic.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };

export class AdoptRigForm extends Component {
  constructor(props) {
    super(props);
    this.state = {
      host: props.ip || "",
      apiPort: DEFAULT_API_PORT,
      controlPort: DEFAULT_CONTROL_PORT,
      token: "",
      busy: false,
      result: null,
    };
  }

  async adopt() {
    const { host, apiPort, controlPort, token } = this.state;
    const validation = validateAdoptFields(host, apiPort, controlPort, token);
    if (validation) {
      this.setState({ result: { status: "error", error: validation } });
      return;
    }
    this.setState({ busy: true, result: null });
    try {
      const cfgRes = await fetch("/api/config");
      if (!cfgRes.ok) throw new Error(`HTTP ${cfgRes.status}`);
      const liveConfig = await cfgRes.json();
      if (hostIsInternal(host, liveConfig?.network?.subnet)) {
        this.setState({
          busy: false,
          result: {
            status: "error",
            error:
              "That address resolves inside this stack's own network — a rig's control address must be a distinct machine on your LAN.",
          },
        });
        return;
      }
      const proposed = buildAdoptedConfig(
        liveConfig,
        this.props.name,
        host,
        apiPort,
        controlPort,
        token,
      );
      let res = await fetch("/api/control/preview", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ config: proposed }),
      });
      if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
      let out = await res.json();
      if (out.status === "pending") out = { id: out.id, ...(await pollResult(out.id)) };
      if (out.status === "rejected") {
        this.setState({ busy: false, result: out });
        return;
      }
      if (out.destructive) {
        // An add-only descriptor never produces a DEST/CONFIRM row; a destructive verdict here
        // means the proposal carried more than the new descriptor — refuse rather than committing
        // something no one reviewed.
        this.setState({
          busy: false,
          result: { status: "error", error: "Unexpected change — nothing was applied." },
        });
        return;
      }
      res = await fetch("/api/control/commit", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ id: out.id }),
      });
      if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
      let committed = await res.json();
      if (committed.status === "pending" || committed.status === "previewed") {
        committed = await pollResult(out.id, "previewed");
      }
      this.setState({ busy: false, result: committed });
      if (committed.status === "applied" && this.props.onAdopted) this.props.onAdopted();
    } catch (e) {
      this.setState({ busy: false, result: { status: "error", error: String(e) } });
    }
  }

  render() {
    const { host, apiPort, controlPort, token, busy, result } = this.state;
    return html`
      <div class="adopt-rig">
        <p class="text-muted text-xs">
          Set up remote control for this rig: confirm its control address (prefilled from what the
          proxy observed — verify it before sending), then add its control token. This writes
          workers.list[] through the same control channel the Configuration view uses.
        </p>
        <label class="config-field">
          <span class="config-field-name">host</span>
          <input type="text" disabled=${busy} value=${host} placeholder="e.g. 192.168.1.10"
              onInput=${(e) => this.setState({ host: e.target.value })} />
        </label>
        <label class="config-field">
          <span class="config-field-name">api_port</span>
          <input type="number" disabled=${busy} value=${apiPort}
              onInput=${(e) => this.setState({ apiPort: e.target.value })} />
        </label>
        <label class="config-field">
          <span class="config-field-name">control_port</span>
          <input type="number" disabled=${busy} value=${controlPort}
              onInput=${(e) => this.setState({ controlPort: e.target.value })} />
        </label>
        <label class="config-field">
          <span class="config-field-name">token</span>
          <input type="password" disabled=${busy} value=${token} placeholder="the rig's control token"
              onInput=${(e) => this.setState({ token: e.target.value })} />
        </label>
        <div class="mt-1">
          <button class="btn-toggle" disabled=${busy} onClick=${() => this.adopt()}>${
            busy ? "Adopting…" : "Adopt this rig"
          }</button>
        </div>
        ${result ? html`<${AdoptStatus} result=${result} />` : null}
      </div>`;
  }
}

function AdoptStatus({ result }) {
  if (result.status === "applied") {
    return html`<p class="text-small mt-1 status-ok">
      Saved to config.json. The dashboard will use the adopted rig on its next worker poll.
    </p>`;
  }
  return html`<p class="text-small mt-1 status-bad">${result.error || result.status}</p>`;
}
