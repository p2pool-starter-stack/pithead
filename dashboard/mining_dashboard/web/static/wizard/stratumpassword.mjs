import { html } from "../app/preact.mjs";
import { RadioField } from "./wizardparts.mjs";

// Generate only on an explicit opt-in. Retained configurations are never rewritten on render.
export function passwordChoice(enabled, current, crypto = globalThis.crypto) {
  if (!enabled) return "";
  if (current) return current;
  return Array.from(crypto.getRandomValues(new Uint8Array(12)), (n) =>
    n.toString(16).padStart(2, "0"),
  ).join("");
}

export const StratumPasswordChoice = ({ value, onChange }) => html`<${RadioField}
  label="Enable stratum password?" name="stratum_password" value=${String(Boolean(value))}
  onChange=${(e) => onChange({ target: { value: passwordChoice(e.target.value === "true", value) } })}
  options=${[
    ["false", "No", "No stratum password (default)."],
    ["true", "Yes", "Generate a password and show it at setup. Every miner needs it."],
  ]} />`;
