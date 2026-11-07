import { Component, html } from "../app/preact.mjs";
import { CONTROL_HEADERS, pollWorkerResult, StatusLine } from "../workers/workerupgrade.mjs";
import { DONATION_LEVELS, dailyCost, rigDonation, timeSentence } from "./donation-model.mjs";

export class DonationControl extends Component {
  state = { choice: null, review: false, confirm: "", busy: false, result: null };

  async apply(target) {
    this.setState({ busy: true, result: { status: "running" } });
    try {
      const res = await fetch("/api/control/worker-apply", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ worker: this.props.name, changes: { DONATION: target } }),
      });
      let out = await res.json();
      if (out.status === "pending") out = await pollWorkerResult(out.id);
      this.setState({ busy: false, review: false, confirm: "", choice: null, result: out });
      this.props.onDone();
    } catch (e) {
      this.setState({ busy: false, result: { status: "error", error: String(e) } });
    }
  }

  render({ worker, rigConfig, earnings, canEdit }, { choice, review, confirm, busy, result }) {
    const current = rigDonation(worker, rigConfig);
    const selected = choice ?? current.configured ?? current.reported;
    const hashrate = Number(worker?.h15) || Number(worker?.h60);
    const cost = dailyCost(choice ?? 0, hashrate, earnings?.available ? earnings.coeff_day : 0);
    return html`<fieldset class="rig-donation" disabled=${busy || !canEdit}>
      <legend>Support the XMRig developers</legend>
      <p>${current.text}. ${current.configured === null ? "This rig does not report its configured level." : `Configured: ${current.configured} %.`}</p>
      ${current.mismatch ? html`<p role="alert">${current.mismatch}</p>` : null}
      <div role="radiogroup" aria-label="Donation level">
        ${DONATION_LEVELS.map(
          (
            level,
          ) => html`<label><input type="radio" name="donation-level" checked=${selected === level}
            onChange=${() => this.setState({ choice: level, review: false, confirm: "" })} /> ${level === 0 ? "Off" : `${level} %`}</label>`,
        )}
      </div>
      <button type="button" disabled=${choice === null || choice === current.configured}
        onClick=${() => this.setState({ review: true })}>Review change</button>
      ${
        review && choice !== null
          ? html`<div class="rig-donation-review">
          <p>Donation: ${choice === 0 ? "Off" : `${choice} %`} of this rig's hashrate goes to the XMRig developers.</p>
          <p>${timeSentence(choice)}</p>
          <p>${cost ? `Estimated cost at this rig's current hashrate: ${cost}.` : "Daily cost is unavailable: the rig's hashrate or the network figures are missing."}</p>
          <label>Type <code>APPLY</code> to confirm <input type="text" value=${confirm}
            onInput=${(event) => this.setState({ confirm: event.target.value })} /></label>
          <button type="button" disabled=${confirm !== "APPLY"} onClick=${() => this.apply(choice)}>${busy ? "Applying…" : "Confirm"}</button>
        </div>`
          : null
      }
      <${StatusLine} result=${result} />
    </fieldset>`;
  }
}
