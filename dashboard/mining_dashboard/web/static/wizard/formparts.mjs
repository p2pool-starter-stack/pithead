import { html } from "../app/preact.mjs";
import { restoreBackLabel } from "./savedrole.mjs";
import { InstallSection, RestoreSection } from "./stages.mjs";
import { Err, Field, Note } from "./wizardparts.mjs";

export function renderRigFields(app) {
  const { rigPool, rigWorker, rigPassword, rigDefaults } = app.state;
  return html`<h3>Where it mines</h3>
        <${Field} label="Pool address (host:port)">
            <input class="wizard-mono" value=${rigPool}
                onInput=${(e) => app.setState({ rigPool: e.target.value })}
                autocomplete="off" autocapitalize="off" spellcheck=${false}
                placeholder="pithead.local:3333" required />
        <//>
        <${Note}>${
          rigDefaults.pool
            ? html`A Pithead answered at ${" "}<code>${rigDefaults.pool}</code>${" "}on this
              network — already filled in.`
            : html`No Pithead answered on this network — enter the coordinator's address by
              hand. Its own setup card names it, as ${" "}
              <code>stratum+tcp://…</code>${" "}under "Point miners at".`
        }<//>
        <${Field} label="Worker name">
            <input value=${rigWorker} onInput=${(e) => app.setState({ rigWorker: e.target.value })}
                autocomplete="off" autocapitalize="off" spellcheck=${false} />
        <//>
        <${Field} label="Stratum password (leave blank unless the Pithead set one)">
            <input type="password" value=${rigPassword}
                onInput=${(e) => app.setState({ rigPassword: e.target.value })}
                autocomplete="new-password" />
        <//>
        <${Note}>That is everything a rig needs. It has no dashboard and no login of its own —
        it appears by this name in the Pithead's Workers view.<//>`;
}

export function renderRestore(app) {
  const { error, installer, disks, chosen, confirm, wipe, restorePassphrase, submitting } =
    app.state;
  const diskPicked = !installer || Boolean(chosen);
  return html`<div class="card">
        <p>Upload an encrypted Pithead backup instead of filling in the form below. The machine
        decrypts, validates and provisions itself from what it restores.</p>
        <${Err}>${error}<//>
        <form onSubmit=${app.submitRestore}>
            ${
              installer &&
              html`<${InstallSection} disks=${disks} chosen=${chosen} confirm=${confirm}
                wipe=${wipe} allowStick=${false}
                onPick=${(e) => app.setState({ chosen: e.target.value, wipe: "keep" })}
                onConfirm=${(e) => app.setState({ confirm: e.target.value })}
                onWipe=${(e) => app.setState({ wipe: e.target.value })} />`
            }
            ${
              diskPicked &&
              html`<${RestoreSection} file=${app.state.restoreFile} passphrase=${restorePassphrase}
                onFile=${(e) => app.setState({ restoreFile: e.target.files[0] || null })}
                onPassphrase=${(e) => app.setState({ restorePassphrase: e.target.value })} />
            <button type="submit" class="btn-toggle active" disabled=${submitting}>
                ${submitting ? "Validating…" : "Restore and provision"}</button>`
            }
        </form>
        <button type="button" class="wizard-link"
            onClick=${() => app.setState({ restoreMode: false, error: "" })}>
            ${restoreBackLabel(app.state.savedRole, app.state.setUpAgain)}</button>
    </div>`;
}
