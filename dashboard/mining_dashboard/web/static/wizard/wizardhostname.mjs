// The coordinator name shares dashboard.host with the later Configuration view.

import { html } from "../app/preact.mjs";
import { pathGet } from "../config/configsync.mjs";
import { Err, Field, Note } from "./wizardparts.mjs";

const RULE =
  "Name this machine: 1–63 lowercase letters, digits or hyphens, starting and ending with a letter or digit; auto and localhost are reserved.";

export function machineNameError(value) {
  return /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(value) &&
    value !== "auto" &&
    value !== "localhost"
    ? ""
    : RULE;
}

export function MachineName({ cfg, edit }) {
  const host = pathGet(cfg, "dashboard.host");
  const legacy = host != null && (host === "" || /[.:_]/.test(host));
  const error = !legacy && host != null && host !== "" ? machineNameError(host) : "";
  return html`<${Field} label="Name this machine">
    <input name="machine_name" value=${legacy ? "" : (host ?? "")}
      onInput=${edit("dashboard.host")} required=${!legacy} maxlength="63"
      pattern=${String.raw`[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?`}
      ref=${(el) => el && el.setCustomValidity(error)}
      autocomplete="off" autocapitalize="off" spellcheck=${false} />
    <//>${
      legacy &&
      html`<${Note}>Keeping the saved dashboard address: ${host || "auto"}.
    Enter a machine name above to replace it.<//>`
    }
    ${error && html`<${Err}>${error}<//>`}
    <${Note}>The dashboard and its addresses become https://&lt;name&gt;.local. Leave the
    default to keep the machine's own name; change it later in Configuration.<//>`;
}
