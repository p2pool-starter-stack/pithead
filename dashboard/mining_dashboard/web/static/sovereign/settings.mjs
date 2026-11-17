import { Component, createRef, html } from "../app/preact.mjs";
import { pathGet } from "../config/configsync.mjs";
import { ConfigView, PreviewModal } from "../config/configview.mjs";
import { runDiag } from "../system/diagview.mjs";

export const LAN_SERVICES = [
  {
    key: "monero.rpc_lan_access",
    service: "Monero wallet RPC",
    port: 18081,
    note: "Wallets on your local network, such as Monero GUI or Feather, reach this node's restricted RPC.",
    connect:
      "In the wallet, choose a remote node and enter this address and port with the node's RPC username and password.",
  },
  {
    key: "monero.zmq_lan_access",
    service: "Monero ZMQ",
    port: 18083,
    note: "Block notifications for other nodes and P2Pool instances on your local network. This feed has no authentication: trusted networks only.",
    connect: "A remote P2Pool on your network needs this port and the wallet RPC port together.",
  },
  {
    key: "tari.grpc_lan_access",
    service: "Tari gRPC",
    port: 18142,
    note: "Another Pithead stack on your local network merge-mines through this node's Tari base node. The gRPC is plaintext: trusted networks only.",
    connect:
      "The other stack points its Tari gRPC address here. Connecting a wallet to this node is not a supported use case.",
  },
];

export function lanHost(snapshot) {
  const host = snapshot?.host_ip;
  const primary = host && host !== "Unknown Host" ? host : snapshot?.host_addr;
  if (!primary || primary === "Unknown Host") return null;
  const alt = snapshot?.host_addr && snapshot.host_addr !== primary ? snapshot.host_addr : null;
  return { primary, alt };
}

export function lanGuardVerdict(doctor) {
  const rows = Array.isArray(doctor?.checks)
    ? doctor.checks.filter((row) => row && ["lan-guard", "lan-guard-hold"].includes(row.id))
    : [];
  if (!rows.length)
    return { status: "unreported", message: "The check did not report the LAN rule." };
  const rank = { fail: 0, warn: 1, info: 2, ok: 3 };
  const worst = rows.reduce(
    (a, b) => ((rank[b.status] ?? 4) < (rank[a.status] ?? 4) ? b : a),
    rows[0],
  );
  const status = ["ok", "warn", "fail"].includes(worst.status) ? worst.status : "info";
  const fallback = {
    ok: "The LAN rule is live.",
    warn: "The LAN rule is in doubt.",
    fail: "The LAN rule is missing.",
    info: "Nothing is published on the LAN.",
  }[status];
  return { status, message: worst.message || fallback };
}

class CopyAddress extends Component {
  state = { status: "" };
  copy = async (text) => {
    try {
      await navigator.clipboard.writeText(text);
      this.setState({ status: "Copied." });
    } catch {
      this.setState({ status: "Copy unavailable. Copy the address manually." });
    }
  };
  render({ text }) {
    return html`<span class="lan-copy">
      <button type="button" onClick=${() => this.copy(text)}>Copy</button>
      ${this.state.status ? html`<span role="status">${this.state.status}</span>` : null}
    </span>`;
  }
}

export class LanGuardStatus extends Component {
  state = { phase: "idle", verdict: null };
  check = async () => {
    this.setState({ phase: "running", verdict: null });
    try {
      const result = await runDiag("diag-doctor", {}, "the LAN rule check");
      this.setState({ phase: "done", verdict: lanGuardVerdict(result.doctor) });
    } catch (error) {
      this.setState({
        phase: "failed",
        verdict: { status: "failed", message: String(error?.message || error) },
      });
    }
  };
  render() {
    const { phase, verdict } = this.state;
    const tone = {
      ok: "ok",
      fail: "fail",
      warn: "warn",
      info: "muted",
      unreported: "muted",
      failed: "fail",
    };
    return html`<div class="lan-guard-status">
      <h3>LAN rule</h3>
      <p class="muted">
        The stack installs a source rule so only local-network and VPN (CGNAT-range) addresses can
        reach these ports. A switch that is on without its rule is a fault, not a working control.
      </p>
      <button
        type="button"
        disabled=${phase === "running"}
        onClick=${() => this.check()}
      >
        ${phase === "running" ? "Checking…" : "Check the LAN rule now"}
      </button>
      ${
        verdict
          ? html`<p
            class=${`lan-verdict lan-${tone[verdict.status] || "muted"}`}
            role=${["fail", "failed", "warn"].includes(verdict.status) ? "alert" : "status"}
          >
            ${verdict.message}
          </p>`
          : html`<p class="muted" role="status">
            Not checked yet. Run the check to see whether the rule is live.
          </p>`
      }
    </div>`;
  }
}

export class LanAccessPanel extends ConfigView {
  async save() {
    if (!this.props.enabled || !this.editable()) return;
    await super.save();
  }
  async commit() {
    if (!this.props.enabled) return;
    await super.commit();
    if (this.state.result?.status === "applied") this.props.onApplied?.();
  }
  componentWillUnmount() {
    this.props.onDirtyChange?.(false);
  }
  editable() {
    const editable = new Set([
      ...this.state.editableKeys,
      ...this.state.confirmKeys,
      ...this.state.approvalKeys,
    ]);
    return LAN_SERVICES.every(({ key }) => editable.has(key));
  }
  render() {
    const { phase, candidate, preview, error, result, confirmText, payoutSuffixes } = this.state;
    const busy = ["loading", "previewing", "committing"].includes(phase);
    const changed = this.state.editText !== this.state.pristine;
    const review = ["confirm", "committing"].includes(phase);
    if (review)
      return html`<${PreviewModal} modalRef=${this.modalRef} preview=${preview}
        confirmText=${confirmText} onConfirmText=${(value) => this.setState({ confirmText: value })}
        payoutSuffixes=${payoutSuffixes} onPayoutSuffix=${(chain, value) =>
          this.setState({ payoutSuffixes: { ...payoutSuffixes, [chain]: value } })}
        onConfirm=${() => this.commit()} onCancel=${() => this.modalRef.current?.close()}
        onClose=${() => this.setState({ phase: "form", preview: null })}
        busy=${phase === "committing"} />`;
    if (phase === "loading") return html`<p role="status">Reading the host's current switches…</p>`;
    if (phase === "disabled")
      return html`<p>The host control channel is off, so these switches are read-only here.
        Enable <code>dashboard.control</code>, or edit the keys and run <code>./pithead apply</code>.</p>`;
    if (phase === "error") return html`<p role="alert">${error}</p>`;
    const host = this.props.host;
    return html`<div class="lan-panel">
      ${LAN_SERVICES.map(({ key, service, port, note, connect }) => {
        const on = pathGet(candidate, key) === true;
        const address = host ? `${host.primary}:${port}` : String(port);
        return html`<div class="lan-row" key=${key}>
          <label class="lan-switch">
            <input
              type="checkbox"
              checked=${on}
              disabled=${busy || !this.editable() || phase === "done"}
              onChange=${(event) =>
                this.onFieldEdit({ key, type: "boolean" }, event.target.checked)}
            />
            <span>${service}</span>
          </label>
          <p class="muted">${note}</p>
          ${
            on
              ? html`<p class="lan-address">
                ${
                  host
                    ? html`<code>${address}</code>
                      <${CopyAddress} text=${address} />
                      ${
                        host.alt
                          ? html`<span class="muted"> or <code>${host.alt}:${port}</code></span>`
                          : null
                      }`
                    : html`Address not detected — use this machine's LAN address with port
                      <code>${port}</code>
                      <${CopyAddress} text=${String(port)} />`
                }
              </p>
              <p class="muted">${connect}</p>`
              : null
          }
        </div>`;
      })}
      ${
        !this.editable()
          ? html`<p role="alert">The host does not permit these switches to be changed here.</p>`
          : null
      }
      ${
        error
          ? html`<p role="alert">
            ${typeof error === "string" ? error : "The host rejected this change."}
          </p>`
          : null
      }
      ${
        phase === "done"
          ? html`<div role="status">
            <p>
              ${
                result?.status === "applied"
                  ? "Applied. Only the affected services restart. Run the LAN rule check to confirm the rule is live."
                  : "The change was not applied. Its host result remains available in the configuration editor."
              }
            </p>
            <button type="button" onClick=${() => this.load()}>Back to the switches</button>
          </div>`
          : null
      }
      ${
        changed && phase !== "done"
          ? html`<button
            type="button"
            class="lan-apply"
            disabled=${busy}
            onClick=${() => this.save()}
          >
            ${phase === "previewing" ? "Preparing review…" : "Review and apply changes"}
          </button>`
          : null
      }
    </div>`;
  }
}

export class SettingsPage extends Component {
  guard = createRef();
  render() {
    const { state, connected = true, sessionExpired = false, onDirtyChange } = this.props;
    const writable = state?.control_enabled === true && connected && !sessionExpired;
    const host = lanHost(state);
    return html`<div class="settings-page">
      <section class="panel lan-group" aria-labelledby="lan-access-title">
        <h2 id="lan-access-title">LAN access</h2>
        <p>
          Share this stack's node ports with devices on your local network or VPN. Each switch
          below writes its existing configuration key, keeps the LAN-only source rule, and never
          exposes a port to the internet. Sharing the node beyond that is not offered here.
        </p>
        ${
          writable
            ? html`<${LanAccessPanel}
                enabled=${true}
                host=${host}
                onDirtyChange=${(dirty) => onDirtyChange?.(dirty)}
                onApplied=${() => this.guard.current?.check()}
              />
              <${LanGuardStatus} ref=${this.guard} />`
            : html`<p class="muted">
              Sign in with an active session on a controllable host to change these switches.
            </p>`
        }
      </section>
    </div>`;
  }
}
