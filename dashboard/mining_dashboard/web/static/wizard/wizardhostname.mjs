// The coordinator name shares dashboard.host with the later Configuration view.

import { html } from "../app/preact.mjs";
import { pathGet } from "../config/configsync.mjs";
import { Field, Note } from "./wizardparts.mjs";

export function MachineName({ cfg, edit }) {
  const host = pathGet(cfg, "dashboard.host");
  const legacy = host != null && (host === "" || /[.:_]/.test(host));
  return html`<${Field} label="Name this machine">
    <input name="machine_name" value=${legacy ? "" : (host ?? "auto")}
      onInput=${edit("dashboard.host")} required=${!legacy} maxlength="63"
      pattern=${String.raw`[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?`}
      autocomplete="off" autocapitalize="off" spellcheck=${false} />
    <//>${
      legacy &&
      html`<${Note}>Keeping the saved dashboard address: ${host || "auto"}.
    Enter a machine name above to replace it.<//>`
    }
    ${(!host || host === "auto") && html`<${Note}>auto keeps the current hostname. Enter a name to change it.<//>`}
    <${Note}>Use 1–63 letters, digits or hyphens; start and end with a letter or digit.
    The dashboard opens at https://&lt;name&gt;.local. Change this later in Configuration.<//>`;
}
