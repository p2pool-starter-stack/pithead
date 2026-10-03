import { html } from "../app/preact.mjs";

// Presentation follows the host-owned stage; steps never advance installation themselves.
export function wizardProgress({ stage, handoff, restoreMode, savedRole, setUpAgain }) {
  if (stage === "gate")
    return {
      step: 0,
      title: "Your machine. Your keys.",
      note: "Start with the one-time token on this machine's console.",
    };
  if (stage === "failed")
    return {
      step: 3,
      title: "Let's get you back on track.",
      note: "Review the failure before trying again. Installation has stopped.",
    };
  if (stage === "installing")
    return {
      step: 3,
      title: "Making itself at home.",
      note: "Keep this machine powered on. Follow its console for progress.",
    };
  if (stage === "done")
    return handoff
      ? {
          step: 2,
          title: "Keep the keys to your operation.",
          note: "Review these details before the machine continues.",
        }
      : {
          step: 3,
          title: "Your operation is starting.",
          note: "The machine's console carries the next steps.",
        };
  return {
    step: 1,
    title: restoreMode
      ? "Bring your operation home."
      : savedRole && !setUpAgain
        ? "Welcome back."
        : "Make this machine yours.",
    note: "Choose its role and storage. Your choices stay under your control.",
  };
}

export function SovereignWizard({ state, children }) {
  const progress = wizardProgress(state);
  return html`<div class="sov-wizard">
    <header class="sov-wizard-brand"><img src="/static/pithead-mark.svg" width="44" height="44" alt="" />
      <div><strong>Pithead</strong><span>APPLIANCE SETUP</span></div><small>SOVEREIGN · EARLY PREVIEW</small></header>
    <div class="sov-wizard-layout">
      <aside class="sov-wizard-guide" aria-label="Setup progress">
        <p class="sov-eyebrow">YOUR CORNER OF THE NETWORK</p>
        <h1>${progress.title}</h1><p>${progress.note}</p>
        <ol>${["Unlock this machine", "Choose your setup", "Review & save", "Install & start"].map(
          (label, i) => html`
          <li aria-current=${i === progress.step ? "step" : null}><span aria-hidden="true">${String(i + 1).padStart(2, "0")}</span>${label}</li>`,
        )}</ol>
        <p class="sov-wizard-footnote">Your hardware.<br />Your hashrate.<br />Your rules.</p>
      </aside>
      <div class="sov-wizard-form">${children}</div>
    </div>
  </div>`;
}
