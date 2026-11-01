import { Component, html } from "../app/preact.mjs";
import { pollResult } from "../config/configview.mjs";
import { controlCommitResult } from "../config/controlclient.mjs";
import {
  buildAdoptedConfig,
  buildRemovedConfig,
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
      host: props.existing ? "" : props.ip || "",
      apiPort: DEFAULT_API_PORT,
      controlPort: DEFAULT_CONTROL_PORT,
      token: "",
      busy: false,
      result: null,
      preview: null,
      confirmText: "",
    };
  }

  async componentDidMount() {
    if (!this.props.existing) return;
    try {
      const res = await fetch("/api/config");
      if (!res.ok) return;
      const entry = ((await res.json())?.workers?.list || []).find((w) => w?.name === this.props.name);
      if (entry)
        this.setState({
          host: entry.host || "",
          apiPort: String(entry.port ?? DEFAULT_API_PORT),
          controlPort: String(entry.control_port ?? DEFAULT_CONTROL_PORT),
        });
    } catch {
      this.setState({ result: { status: "error", error: "The current address could not be loaded." } });
    }
  }

  adopt() {
    const { host, apiPort, controlPort, token } = this.state;
    return this.propose(
      validateAdoptFields(host, apiPort, controlPort, token, this.props.existing),
      (live) => buildAdoptedConfig(live, this.props.name, host, apiPort, controlPort, token),
      host,
    );
  }

  remove() {
    return this.propose("", (live) => buildRemovedConfig(live, this.props.name), "");
  }

  async propose(validation, build, host) {
    if (validation) {
      this.setState({ result: { status: "error", error: validation } });
      return;
    }
    this.setState({ busy: true, result: null, preview: null, confirmText: "" });
    try {
      const cfgRes = await fetch("/api/config");
      if (!cfgRes.ok) throw new Error(`HTTP ${cfgRes.status}`);
      const liveConfig = await cfgRes.json();
      if (host && hostIsInternal(host, liveConfig?.network?.subnet)) {
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
      const proposed = build(liveConfig);
      const res = await fetch("/api/control/preview", {
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
      const reviewed = (out.changes || []).filter((c) => c.flag === "DEST" || c.flag === "CONFIRM");
      if (reviewed.some((c) => c.key !== "workers.list")) {
        this.setState({
          busy: false,
          result: { status: "error", error: "Unexpected change — nothing was applied." },
        });
        return;
      }
      this.setState({ busy: false, preview: out });
    } catch (e) {
      this.setState({ busy: false, result: { status: "error", error: String(e) } });
    }
  }

  async confirm() {
    const { preview, confirmText } = this.state;
    this.setState({ busy: true });
    try {
      const res = await fetch("/api/control/commit", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ id: preview.id, confirm: confirmText }),
      });
      if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
      const committed = await controlCommitResult(res, preview.id, pollResult);
      this.setState({ busy: false, preview: null, confirmText: "", result: committed });
      if (committed.status === "applied" && this.props.onAdopted) this.props.onAdopted();
    } catch (e) {
      this.setState({ busy: false, preview: null, result: { status: "error", error: String(e) } });
    }
  }

  render() {
    const { host, apiPort, controlPort, token, busy, result, preview, confirmText } = this.state;
    const { existing } = this.props;
    return html`
      <div class="adopt-rig">
        <p class="text-muted text-xs">
          ${
            existing
              ? "Change where the dashboard reaches this rig. Leave the token blank to keep it; a new address needs the token entered again. You confirm by typing APPLY."
              : "Set up remote control for this rig: confirm its control address (prefilled from what the proxy observed — verify it before sending), then add its control token. You confirm by typing APPLY."
          }
        </p>
        <label class="config-field">
          <span class="config-field-name">host</span>
          <input type="text" disabled=${busy || !!preview} value=${host} placeholder="e.g. 192.168.1.10"
              onInput=${(e) => this.setState({ host: e.target.value })} />
        </label>
        <label class="config-field">
          <span class="config-field-name">api_port</span>
          <input type="number" disabled=${busy || !!preview} value=${apiPort}
              onInput=${(e) => this.setState({ apiPort: e.target.value })} />
        </label>
        <label class="config-field">
          <span class="config-field-name">control_port</span>
          <input type="number" disabled=${busy || !!preview} value=${controlPort}
              onInput=${(e) => this.setState({ controlPort: e.target.value })} />
        </label>
        <label class="config-field">
          <span class="config-field-name">token</span>
          <input type="password" disabled=${busy || !!preview} value=${token} placeholder=${existing ? "blank keeps the current token" : "the rig's control token"}
              onInput=${(e) => this.setState({ token: e.target.value })} />
        </label>
        ${
          preview
            ? html`<${AdoptConfirm} preview=${preview} confirmText=${confirmText} busy=${busy}
                  onConfirmText=${(t) => this.setState({ confirmText: t })}
                  onConfirm=${() => this.confirm()}
                  onCancel=${() => this.setState({ preview: null, confirmText: "" })} />`
            : html`<div class="mt-1">
                <button class="btn-toggle" disabled=${busy} onClick=${() => this.adopt()}>${
                  busy ? "Checking…" : existing ? "Save address" : "Adopt this rig"
                }</button>
                ${
                  existing
                    ? html`<button class="btn-toggle" disabled=${busy} onClick=${() => this.remove()}>Remove this rig</button>`
                    : null
                }
              </div>`
        }
        ${result ? html`<${AdoptStatus} result=${result} />` : null}
      </div>`;
  }
}

function AdoptConfirm({ preview, confirmText, busy, onConfirmText, onConfirm, onCancel }) {
  return html`<div class="mt-1">
    ${(preview.changes || []).map((c) => html`<p class="text-small status-bad">${c.msg}</p>`)}
    <label class="config-confirm-type">Type <code>APPLY</code> to confirm:
        <input type="text" disabled=${busy} value=${confirmText}
            onInput=${(e) => onConfirmText(e.target.value)} /></label>
    <div class="mt-1">
      <button class="btn-toggle active" disabled=${busy || confirmText !== "APPLY"} onClick=${onConfirm}>${
        busy ? "Applying…" : "Confirm"
      }</button>
      <button class="btn-toggle" disabled=${busy} onClick=${onCancel}>Cancel</button>
    </div>
  </div>`;
}

function AdoptStatus({ result }) {
  if (result.status === "applied") {
    return html`<p class="text-small mt-1 status-ok">
      Saved to config.json. The dashboard uses the change on its next worker poll.
    </p>`;
  }
  return html`<p class="text-small mt-1 status-bad">${result.error || result.status}</p>`;
}
