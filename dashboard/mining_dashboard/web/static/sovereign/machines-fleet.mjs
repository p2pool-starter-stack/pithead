import { Component, html } from "../app/preact.mjs";
import { CONTROL_HEADERS } from "../workers/workerupgrade.mjs";
import { fleetControl, runView } from "./machines-fleet-model.mjs";

const PATH = "/api/control/worker-upgrade-all";
const RUNNING_MS = 3000;
const IDLE_MS = 30000;

export class FleetUpgrade extends Component {
  state = { plan: null, run: null, open: false, busy: false, error: "" };
  componentDidMount() {
    this.refresh();
  }
  componentWillUnmount() {
    this.gone = true;
    clearTimeout(this.timer);
  }
  async refresh() {
    try {
      const response = await fetch(PATH, { cache: "no-store" });
      if (!response.ok) throw new Error();
      const { run, ...plan } = await response.json();
      if (!this.gone) this.setState({ plan, run });
    } catch {
      if (!this.gone) this.setState({ plan: null });
    }
    if (this.gone) return;
    this.timer = setTimeout(
      () => this.refresh(),
      this.state.run?.status === "running" ? RUNNING_MS : IDLE_MS,
    );
  }
  async start() {
    const { plan } = this.state;
    this.setState({ busy: true, error: "" });
    try {
      const response = await fetch(PATH, {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ version: plan.version }),
      });
      if (!response.ok) {
        const text = await response.text();
        throw new Error(text || `HTTP ${response.status}`);
      }
      const accepted = await response.json();
      this.setState({
        busy: false,
        open: false,
        run: {
          status: "running",
          version: plan.version,
          ts: Date.now() / 1000,
          rigs: (accepted.rigs || []).map((name) => ({ name, status: "pending" })),
        },
      });
      clearTimeout(this.timer);
      this.timer = setTimeout(() => this.refresh(), RUNNING_MS);
      this.opener?.focus();
    } catch (error) {
      this.setState({ busy: false, error: error.message || "The update could not be started." });
      clearTimeout(this.timer);
      this.refresh();
    }
  }
  render({ controlEnabled, writable }, { plan, run, open, busy, error }) {
    const view = runView(run);
    const offer = fleetControl({ controlEnabled, writable, plan, run });
    const skipped = Array.isArray(plan?.skipped) ? plan.skipped : [];
    return html`<div class="fleet-upgrade">
      ${
        offer
          ? html`<button type="button" onClick=${(event) => {
              this.opener = event.currentTarget;
              this.setState({ open: true, error: "" });
            }}>Update all rigs to ${plan.version}</button>`
          : null
      }
      ${error && !(open && offer) ? html`<p role="alert">${error}</p>` : null}
      ${
        view
          ? html`<section class="fleet-run" aria-labelledby="fleet-run-title"><h3 id="fleet-run-title">Update all rigs</h3>
          <p role="status">${view.headline}</p>
          <ul>${view.rigs.map((rig) => html`<li key=${rig.name}>${rig.name}: ${rig.word}${rig.reason ? html` <span class="rig-note">${rig.reason}</span>` : null}</li>`)}</ul>
        </section>`
          : null
      }
      ${
        open && offer
          ? html`<dialog class="fleet-review" aria-labelledby="fleet-review-title"
            ref=${(element) => element && !element.open && element.showModal?.()}
            onClose=${() => {
              this.setState({ open: false });
              this.opener?.focus();
            }}>
          <h2 id="fleet-review-title">Update all rigs to ${plan.version}</h2>
          <p>One rig at a time. A rig that fails does not stop the others.</p>
          <h3>Will be upgraded</h3>
          <ul>${plan.eligible.map((rig) => html`<li key=${rig.name}>${rig.name}: ${rig.running} to ${plan.version}</li>`)}</ul>
          ${
            skipped.length
              ? html`<h3>Cannot be upgraded</h3>
            <ul>${skipped.map((rig, index) => html`<li key=${index}>${rig.name}: ${rig.reason}</li>`)}</ul>`
              : null
          }
          ${error ? html`<p role="alert">${error}</p>` : null}
          <button type="button" disabled=${busy} onClick=${() => this.start()}>${busy ? "Starting…" : "Start update"}</button>
          <button type="button" disabled=${busy} onClick=${(event) => event.currentTarget.closest("dialog").close()}>Cancel</button>
        </dialog>`
          : null
      }
    </div>`;
  }
}
