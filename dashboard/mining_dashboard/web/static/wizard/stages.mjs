import { html } from "../app/preact.mjs";
import { rigCardFields, rigCardNote } from "../workers/rigcardlogic.mjs";
import { Err, Field, Note } from "./wizardparts.mjs";

export const Gate = ({ error, onSubmit }) => html`<div class="card">
    <p>Enter the one-time token shown on this machine's console or terminal.</p>
    <${Err}>${error}<//>
    <form onSubmit=${onSubmit}>
        <${Field} label="Token">
            <input name="token" autofocus autocomplete="off" autocapitalize="off"
                spellcheck=${false} placeholder="pit-XXXXXX" />
        <//>
        <${Note}>Case doesn't matter, and the ${" "}<code>pit-</code>${" "}prefix is optional.<//>
        <button type="submit" class="btn-toggle active">Continue</button>
    </form>
</div>`;

// Disk picker: the consequence sits right after the disk name (a <select> truncates on the
// right — bench screenshots cut off exactly the erase/keep words), and is restated in full
// below the control, red when destructive. The server re-validates the choice against the
// inventory the HOST published; a browser can never name a disk the host did not offer.
export const InstallSection = ({
  disks,
  chosen,
  confirm,
  wipe,
  allowStick,
  onPick,
  onConfirm,
  onWipe,
}) => {
  const picked = disks.find((d) => d.name === chosen);
  const verdictText = (d) =>
    d.state === "pithead-with-data"
      ? "holds a previous install"
      : d.state === "pithead"
        ? "ERASES it (Pithead layout, no data partition)"
        : "ERASES everything on it";
  return html`<div>
    <h3>Install onto</h3>
    <${Field} label="Target disk">
        <select value=${chosen} onChange=${onPick}>
            <option value="" disabled selected=${!chosen}>Choose a disk…</option>
            ${
              // A rig holds almost no state, so for that role the stick itself is a
              // first-class place to live — no erase, no commitment on machines whose
              // disks belong to something else.
              allowStick &&
              html`<option value="usb">Run from this USB stick — nothing is erased</option>`
            }
            ${disks.map(
              (d) =>
                html`<option value=${d.name}>
                    ${d.name} — ${verdictText(d)} — ${d.size} ${d.model} (SN ${d.serial})
                </option>`,
            )}
        </select>
    <//>
    ${
      chosen === "usb" &&
      html`<${Note}>The stick stays in the machine and is the system: the rig's settings ride
        on it, no disk is touched, and pulling it out just stops the miner.<//>`
    }
    ${
      picked &&
      picked.state === "pithead-with-data" &&
      html`<${Field} label="It holds a previous install — what happens to its data?">
        <select value=${wipe} onChange=${onWipe}>
            <option value="keep">Keep everything — settings, wallets and the synced chains (default)</option>
            <option value="data">Fresh start, keep the blockchains — settings and wallets are wiped</option>
            <option value="all">Wipe everything — the chains re-download from scratch</option>
        </select>
    <//>`
    }
    ${
      picked &&
      picked.state === "pithead-with-data" &&
      wipe === "all" &&
      html`<p class="c-bad">Everything on ${picked.name} is erased — including synced chains
        that took days to download.</p>`
    }
    ${
      picked &&
      picked.state !== "pithead-with-data" &&
      html`<p class="c-bad">Installing to ${picked.name} — this ${verdictText(picked)}.</p>`
    }
    ${
      picked &&
      html`<${Field} label="Type the disk name to confirm">
        <input value=${confirm} onInput=${onConfirm} autocomplete="off" autocapitalize="off"
            spellcheck=${false} placeholder=${chosen} />
    <//>`
    }
</div>`;
};

// Restore-at-setup (#909): the config form's alternative — an uploaded encrypted backup +
// its emergency-kit passphrase. Validation is host-side (the same "container asks, host
// decides" split as everything else here); this just carries the two answers up.
export const RestoreSection = ({ file, passphrase, onFile, onPassphrase }) => html`<div>
    <h3>Restore from a backup</h3>
    <${Note}>Upload the encrypted backup archive and its emergency-kit passphrase — shown once,
    when the backup was made. This restores settings, wallets, keys and the dashboard's history;
    the machine then provisions itself from what it restores, exactly as if you had filled in
    the form.<//>
    <${Field} label="Backup archive">
        <input type="file" accept=".enc,.tar.gz" onChange=${onFile} />
    <//>
    ${file && html`<p class="text-muted">${file.name} (${Math.round(file.size / 1024)} KB)</p>`}
    <${Field} label="Passphrase">
        <input type="password" value=${passphrase} onInput=${onPassphrase}
            autocomplete="off" placeholder="the emergency-kit passphrase" />
    <//>
</div>`;

export const Installing = ({ status }) => html`<div class="card">
    <p><strong>Installing.</strong> Takes a few minutes. Do not power it off.</p>
    ${
      status.startsWith("Installed")
        ? html`<h3>Installed</h3>
            <ol>
                <li>Wait for the machine to switch itself off.</li>
                <li>Remove the USB stick.</li>
                <li>Switch it back on.</li>
            </ol>
            <${Note}>Nothing more to configure: the machine provisions itself from the
            configuration you confirmed, then serves the dashboard behind the login you
            saved.<//>`
        : html`<p class="text-muted">${status || "Working…"}</p>`
    }
</div>`;

export const Done = ({ status, handoff, installer, stick, rig, onAck }) => html`<div class="card">
    ${
      handoff && handoff.role === "rig"
        ? html`<h3>Check this rig</h3>
            <p>This is what the machine will be.</p>
            ${rigCardFields(handoff).map((f) => html`<${Field} label=${f.label}><code class="wizard-mono">${f.value}</code><//>`)}
            <${Note}>${rigCardNote(handoff)}<//>
            <button type="button" class="btn-toggle active" onClick=${onAck}>
                ${installer && !stick ? "Looks right — erase the disk and install" : "Looks right — save it"}</button>`
        : handoff
          ? html`<h3>Save this before anything else</h3>
            <p>This is shown once, here.</p>
            <${Field} label="Dashboard user"><code class="wizard-mono">${handoff.username}</code><//>
            <${Field} label="Dashboard password"><code class="wizard-mono">${handoff.password}</code><//>
            <${Field} label="Dashboard address"><code class="wizard-mono">${handoff.dashboard}</code><//>
            <${Field} label="Point miners at"><code class="wizard-mono">${handoff.stratum}</code><//>
            <button type="button" class="btn-toggle active" onClick=${onAck}>
                ${installer ? "I saved these — erase the disk and install" : "I saved these — start provisioning"}</button>
            <${Note}>${
              installer
                ? html`Nothing is written to the disk until you press this. The machine installs,
                  switches itself off, and provisions with this exact configuration when you
                  power it back on — these credentials are the ones it will serve.`
                : html`Provisioning waits for this confirmation (up to 10 minutes), because the
                  page goes dark while the machine builds itself.`
            }<//>`
          : rig
            ? html`<p><strong>Saved.</strong> The miner is starting on this machine now. It has no
            dashboard of its own, so this page is the last one it shows — the rig appears in your
            Pithead's Workers view once it connects, and its console narrates until then.</p>
            <p class="text-muted">${status || ""}</p>`
            : html`<p><strong>Provisioning.</strong> The machine is pulling and starting the stack —
            10 to 30 minutes on a home connection. <strong>This page will stop responding</strong>
            while it happens; that is the machine working, not failing. Its console narrates, and
            when it finishes the dashboard is at
            ${" "}<code class="wizard-mono">${handoff ? handoff.dashboard : "https://pithead.local"}</code>${" "}
            behind the login you just saved.</p>
            <p class="text-muted">${status || "Waiting…"}</p>`
    }
</div>`;
