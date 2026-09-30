// The reboot step of a dashboard-driven OS update, and the header badge that survives it (#2385).
//
// Its own module rather than more of osupdate.mjs, on the same terms as osverdict.mjs: that file
// is at its recorded budget ceiling with no headroom, and this is a self-contained concern — the
// host's step and the chosen version in, display text and panes out, with no fetching, polling or
// state of its own. The caller owns every decision; nothing here calls the control spool.
//
// The reboot is asked for twice on purpose. install() lands on a plain "reboot now?" so the
// ordinary answer is one click, and the typed confirmation stays one click further on, because
// that is the step that pauses mining. Neither pane may reboot the machine implicitly.

import { html } from "../app/preact.mjs";

// The host reports a bare version ("1.19.0"); operators read tags ("v1.19.0"). One spelling, used
// by every caller that shows a version to a person, so the two never drift apart.
export const vtag = (v) => (v.startsWith("v") ? v : "v" + v);

// What the header badge says. The reboot-pending case names the target so a closed modal — or a
// reloaded page — still tells the operator which update is waiting on them, not merely that one is.
export function osBadgeLabel(os, passive) {
  if (os.step === "reboot-pending") {
    const target = os.version ? vtag(os.version) : "the installed release";
    return `Reboot to finish the update to ${target}`;
  }
  if (passive && passive.available) return `OS update ${passive.latest}`;
  return "OS updates";
}

// The plain ask, straight after a successful install. Deliberately NOT the typed gate: an operator
// who wants the reboot now should not have to type to get it, and one who does not can decline
// without the modal implying the update is unfinished business they must resolve here.
export function rebootAskPane({ version, onNotNow, onReboot }) {
  return html`<p class="status-ok">${version || "The update"} is installed — reboot now?</p>
      <div class="config-modal-actions">
          <button class="btn-toggle" onClick=${onNotNow}>Not now</button>
          <button class="btn-toggle active" onClick=${onReboot}>Reboot</button>
      </div>`;
}

// The typed gate, one click behind the ask. Mining pauses here, so the confirmation is deliberate
// friction; the rollback sentence is what makes accepting it reasonable rather than brave.
export function rebootConfirmPane({ version, confirmText, onConfirmText, onLater, onReboot }) {
  return html`<p class="status-ok">${version || "The update"} is installed in the spare slot.</p>
      <p>Reboot to finish. Mining pauses while the machine restarts — typically under five
      minutes — and if the new version fails its health checks the machine returns to the
      current one on its own.</p>
      <label class="config-confirm-type">Type <code>REBOOT</code> to confirm:
          <input type="text" value=${confirmText} onInput=${onConfirmText} /></label>
      <div class="config-modal-actions">
          <button class="btn-toggle" onClick=${onLater}>Later</button>
          <button class="btn-toggle active" disabled=${confirmText !== "REBOOT"}
              onClick=${onReboot}>Reboot now</button>
      </div>`;
}
