// The wizard's two opt-in mining questions: whether this machine merge-mines Tari (#1855) and
// whether it joins the XvB raffle (#1848). They live here rather than in wizard.mjs because that
// file is at its budget ceiling, and because the Tari answer is not a boolean — it decides
// whether a whole block of the form exists — so the mapping from a stored `tari.mode` to the
// answer shown is worth proving without a browser.

import { html } from "../app/preact.mjs";
import { Field, Note, RadioField } from "./wizardparts.mjs";

// Which of the three answers a stored `tari.mode` is, for the question to show.
//
// Only the literal "off" reads as declined. Everything else — a missing key included — is a yes,
// because that is what the host does with a config written before the question existed
// (`lib/pithead/28-parse-and-validate-config.sh`: no key means `local`). Reading an absent key as
// "off" would show an upgraded 1.x install as having declined merge-mining, and submitting that
// screen would then write the decline back.
//
// The opposite coercion is what this replaces: the select used to be `remoteTari ? "remote" :
// "local"`, which had no way to say "off" at all — a machine that had declined rendered as
// "local" and submit wrote `local` back, silently re-enabling the merge-mining its operator
// turned down.
export function tariAnswer(mode) {
  if (mode === "off") return "off";
  return mode === "remote" ? "remote" : "local";
}

// The Tari merge-mining question and everything that hangs off a yes.
//
// The payout address moved in here from the Payout addresses section: a machine that does not
// merge-mine has nowhere to be paid in Tari, and the field carried `required`, so leaving it up
// there would have blocked submit on a form that never asks the question. `required` stays on it
// for a yes — that is the same bar the Monero address holds.
export const TariSection = ({ answer, v, on }) => html`<h2>Tari merge-mining</h2>
    <${RadioField} label="Merge-mine Tari?" name="tari-mode" value=${answer}
        onChange=${on("tariMode")} options=${[
          ["off", "No", "Mine Monero only."],
          ["local", "Yes, with the bundled node", "Run a Tari node on this machine."],
          ["remote", "Yes, with my node", "Use a Tari node I already run."],
        ]} />
    <${Note}>Merge-mining earns Tari from the same work that mines Monero, so it costs no
    hashrate — but it needs its own payout address and a node of its own, and the bundled node
    adds a 200 GiB disk budget on top of Monero's. The Configuration view carries this switch, so
    you can turn it off and back on later behind a typed APPLY; turning it off keeps the chain data
    on disk, so it resumes rather than re-syncing. Answering No stores no payout address, and
    adding one later needs the approval step.<//>
    ${
      answer !== "off" &&
      html`<div class="wizard-when">
        <${Field} label="Tari payout address">
            <input class="wizard-mono" value=${v("tariWallet") || ""} onInput=${on("tariWallet")}
                autocomplete="off" autocapitalize="off" spellcheck=${false} required />
        <//>
        <${Note}>Paste it — like the Monero address, it is far too long to type, and a typo pays
        a stranger.<//>
        ${
          answer === "remote" &&
          html`<${Field} label="Node host">
            <input value=${v("tariRemoteHost") || ""} onInput=${on("tariRemoteHost")}
                placeholder="192.168.1.10 or my-node.local" autocomplete="off" spellcheck=${false} />
        <//>
        <${Field} label="gRPC port">
            <input value=${v("tariRemoteGrpc") ?? 18142} onInput=${on("tariRemoteGrpc")}
                inputmode="numeric" pattern="[0-9]+" />
        <//>
        <${Note}>An IP or a hostname both work. Only over a network you trust — this connection
        is not encrypted.<//>`
        }
      </div>`
    }`;

// Measurements come from the host, including the target's future data partition.
export function tariDiskDefault(budget, disks, target, moneroMode, wipe = "keep") {
  const disk = disks.find((item) => item.name === target);
  const key =
    disk?.state === "pithead-with-data" && wipe === "data" ? "data_available_bytes" : "data_bytes";
  const available = disks.length ? disk?.[key] : budget.available_bytes;
  const need = moneroMode === "remote" ? budget.remote_need_bytes : budget.local_need_bytes;
  return Number.isFinite(available) && Number.isFinite(need) && available < need ? "off" : "local";
}

export function syncInitialChains(cfg, fast) {
  for (const chain of ["monero", "tari"]) {
    if (!Object.hasOwn(cfg, chain)) cfg[chain] = {};
    const section = cfg[chain];
    if (section && typeof section === "object" && !Array.isArray(section)) {
      section.clearnet_initial_sync = fast && (section.mode ?? "local") === "local";
    }
  }
}

export function fastSyncWarning(cfg) {
  const networks = ["monero", "tari"]
    .filter((chain) => cfg[chain]?.clearnet_initial_sync)
    .map((chain) => `the ${chain === "monero" ? "Monero" : "Tari"} network`);
  return networks.length
    ? `Fast sync exposes your IP address to ${networks.join(" and ")} until the initial sync finishes.`
    : "";
}

export function applyDiskDefault(app, cfg, chosen = app.state.chosen, wipe = app.state.wipe) {
  if (app.state.newMachine && !app.state.tariTouched) {
    cfg.tari ||= {};
    cfg.monero ||= {};
    cfg.tari.mode = tariDiskDefault(
      app.state.diskBudget,
      app.state.disks,
      chosen,
      cfg.monero.mode,
      wipe,
    );
  }
}

export function selectTarget(app, chosen, wipe) {
  const cfg = app.state.cfg;
  applyDiskDefault(app, cfg, chosen, wipe);
  syncInitialChains(cfg, app.state.fastSync);
  app.setState({ chosen, wipe, cfg, jsonText: JSON.stringify(cfg, null, 2) });
}
