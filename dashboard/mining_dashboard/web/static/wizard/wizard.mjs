import { Component, html, render } from "../app/preact.mjs";
import { jsonSyntaxError } from "../config/configlogic.mjs";
import { coerceForPath, pathSet } from "../config/configsync.mjs";
import { needsNodeProbe } from "../network/nodeprobe.mjs";
import { renderRestore, renderRigFields } from "./formparts.mjs";
import { savedRoleOrSetup } from "./savedrole.mjs";
import { renderSetup } from "./setup.mjs";
import { Done, Gate, Installing } from "./stages.mjs";
import * as failure from "./wizardfailure.mjs";

const RESTORE_MAX_BYTES = 64 * 1024 * 1024;

export class WizardApp extends Component {
  state = {
    stage: "gate", // gate | setup | install | installing | done
    error: "",
    cfg: {},
    reference: {},
    disks: [],
    chosen: "",
    confirm: "",
    wipe: "keep",
    submitting: false,
    probing: false,
    jsonText: "",
    jsonError: "",
    authMode: "auto", // auto | set | none — travels beside the config (see wizard.py submit)
    // What this machine IS, asked above the disk. ONLY "rig" is stored — it is the one answer
    // that carries no config; the two coordinators are read back out of one (see renderSetup).
    role: "",
    rigPool: "",
    rigWorker: "",
    rigPassword: "",
    rigDefaults: {},
    // The data-wipe note (#1121): set when /data was reinitialized before this boot. Only
    // `recovery: true` ever renders — a deliberate factory-reset is not a surprise to the
    // operator who asked for it.
    dataWiped: {},
    // Restore-at-setup (#909): an alternative to the whole form above, toggled independently
    // of role/install-target — an uploaded backup replaces the config the operator would
    // otherwise type in.
    restoreMode: false,
    restoreFile: null,
    restorePassphrase: "",
    status: "",
    handoff: null,
  };

  // The SERVER decides which step this machine is on (wizard_stage, from the spool). The client
  // never infers it: a refresh mid-provision used to walk back into an editable form, and a
  // client-side stage flag raced its own setState so the credentials card could never appear.
  async loadState() {
    const res = await fetch("/api/wizard-state");
    if (!res.ok) return false;
    const s = await res.json();
    const next = {
      // The installation medium gets the SAME setup form with an install section folded in —
      // one page, one submission (config + disk + wipe), one credentials card, then the erase.
      ...failure.restoredState(s, this.state),
      reference: s.reference,
      disks: s.disks,
      error: s.error || "",
      rigDefaults: s.rig_defaults || {},
      dataWiped: s.data_wiped || {},
      handoff: s.handoff || null,
      savedRole: s.saved_role || null,
      nodeProbe: s.node_probe || null,
    };
    // The host's discovery pre-fills the rig fields, but only while they are untouched — the
    // form polls, and a half-typed pool address must survive it (same rule as cfg below).
    if (!this.state.rigPool && !this.state.rigWorker) {
      next.rigPool = (s.rig_defaults || {}).pool || "";
      next.rigWorker = (s.rig_defaults || {}).worker || "";
    }
    // The wait is over once the server either moved on or rejected: both end "Validating…".
    if (this.state.submitting && (next.stage !== "setup" || next.error)) next.submitting = false;
    // Do not clobber in-progress editing with the server's copy once the form is up.
    if (this.state.stage !== "setup" || !this.state.cfg || !Object.keys(this.state.cfg).length) {
      next.cfg = s.config;
      next.jsonText = JSON.stringify(s.config, null, 2);
    }
    this.setState(next);
    return true;
  }

  async componentDidMount() {
    await this.loadState(); // an existing session cookie skips the gate
  }

  // One loop after submit: refresh the SERVER's stage (which carries the handoff when it is
  // published) and the human-readable status line. No client-side stage guessing.
  poll() {
    const tick = async () => {
      try {
        this.setState({ status: await (await fetch("/status")).text() });
        await this.loadState();
      } catch {
        /* the machine reboots or powers off under this poll by design */
      }
      setTimeout(tick, 2000);
    };
    tick();
  }

  // A dropped connection reads identically to the lockout to the operator: the machine
  // exits right after refusing the last attempt, so a network failure gets the same
  // actionable message as the 429 it raced.
  static LOCKOUT_MESSAGE =
    "Too many attempts — the machine printed a fresh token on its console; enter that one.";

  auth = async (e) => {
    e.preventDefault();
    try {
      const res = await fetch("/auth", {
        method: "POST",
        body: new URLSearchParams(new FormData(e.target)),
      });
      if (res.ok && (await this.loadState())) return;
      if (res.status === 429) {
        this.setState({ error: WizardApp.LOCKOUT_MESSAGE });
        return;
      }
      this.setState({ error: "Wrong token." });
    } catch {
      this.setState({ error: WizardApp.LOCKOUT_MESSAGE });
    }
  };

  // Field edit → config → JSON pane. The JSON is the single source of what gets submitted.
  edit = (path) => (e) => {
    const raw = e.target.type === "checkbox" ? String(e.target.checked) : e.target.value;
    const cfg = this.state.cfg;
    pathSet(cfg, path, coerceForPath(this.state.reference, path, raw));
    this.setState({ cfg, jsonText: JSON.stringify(cfg, null, 2) });
  };

  // The role reshapes the page the way the disk choice does. "Both" IS the existing
  // local_miner switch: picking it turns that switch on, plain Pithead turns it off, and the
  // switch below stays live either way. Neither is stored; a rig never touches the config.
  setRole = (e) => {
    const role = e.target.value;
    const cfg = this.state.cfg;
    const next = { role: role === "rig" ? "rig" : "", cfg };
    if (role !== "rig") {
      pathSet(cfg, "local_miner.enabled", role === "both");
      // "usb" only exists for rigs — a coordinator switching back must re-pick a real disk.
      if (this.state.chosen === "usb") {
        next.chosen = "";
        next.confirm = "";
      }
    }
    next.jsonText = JSON.stringify(cfg, null, 2);
    this.setState(next);
  };

  // JSON pane edit → config → fields. Hand-edited JSON wins; shape errors show as typed.
  editJson = (e) => {
    const text = e.target.value;
    const err = jsonSyntaxError(text);
    if (err) {
      this.setState({ jsonText: text, jsonError: err });
      return;
    }
    this.setState({ jsonText: text, jsonError: "", cfg: JSON.parse(text) });
  };

  submit = async (e) => {
    e.preventDefault();
    const rig = this.state.role === "rig";
    const keepEverything =
      this.state.installer &&
      (this.state.disks.find((d) => d.name === this.state.chosen) || {}).state ===
        "pithead-with-data" &&
      this.state.wipe === "keep";
    // keep means KEEP in every role: no config, no role — the survivor wins.
    const body = keepEverything
      ? {} // the preserved config wins — sending one would only mislead
      : rig
        ? {
            role: "rig",
            rig_pool: this.state.rigPool.trim(),
            rig_worker: this.state.rigWorker.trim(),
            rig_password: this.state.rigPassword,
          }
        : {
            config: JSON.stringify(this.state.cfg),
            auth_mode: this.state.authMode,
          };
    if (rig && !keepEverything && !body.rig_pool) {
      this.setState({ error: "Enter the pool address (host:port)." });
      return;
    }
    // One page, one submission: on the installation medium the disk choice rides beside the
    // config, and the server gates both before anything is written. "usb" (rig role only) is
    // not a disk: nothing is erased, so the retyped-name gate does not apply.
    if (this.state.installer) {
      if (!this.state.chosen) {
        this.setState({
          error: rig
            ? "Choose a disk — or run from this USB stick."
            : "Choose the disk to install onto.",
        });
        return;
      }
      if (this.state.chosen === "usb") {
        body.disk = "usb";
      } else {
        if (this.state.confirm !== this.state.chosen) {
          this.setState({ error: `Type ${this.state.chosen} exactly to confirm the erase.` });
          return;
        }
        body.disk = this.state.chosen;
        body.confirm = this.state.confirm;
        body.wipe = this.state.wipe;
      }
    }
    const probing = !rig && !keepEverything && needsNodeProbe(this.state.cfg);
    this.setState({ submitting: true, probing, error: "" });
    let res;
    try {
      res = await fetch("/submit", { method: "POST", body: new URLSearchParams(body) });
    } catch {
      this.setState({
        submitting: false,
        probing: false,
        error: "Could not reach this machine. Retry when it is available.",
      });
      return;
    }
    if (!res.ok) {
      let msg = "Submit failed — check the configuration and retry.";
      let nodeProbe = null;
      try {
        const failure = await res.json();
        msg = failure.error || msg;
        nodeProbe = failure.node_probe || null;
      } catch {}
      this.setState({ submitting: false, probing: false, error: msg, nodeProbe });
      return;
    }
    // No optimistic view swap: flipping the stage locally re-rendered a different page and
    // threw the scroll to the top while nothing had happened yet. The button reads
    // "Validating…" in place, and the page changes when the SERVER's stage does.
    this.setState({ probing: false });
    this.poll();
  };

  // The restore-at-setup alternative (#909): an uploaded archive + passphrase instead of the
  // typed config. Multipart, not URLSearchParams — the archive is a file, not a form field.
  // Validation is entirely host-side; the client only enforces the size cap it can check
  // without a round trip.
  submitRestore = async (e) => {
    e.preventDefault();
    if (!this.state.restoreFile) {
      this.setState({ error: "Choose a backup archive to upload." });
      return;
    }
    if (this.state.restoreFile.size > RESTORE_MAX_BYTES) {
      this.setState({
        error: `Archive is too large (max ${RESTORE_MAX_BYTES / (1024 * 1024)} MB) — a Pithead backup holds only config, keys and the dashboard database, never the blockchains.`,
      });
      return;
    }
    const body = new FormData();
    body.append("archive", this.state.restoreFile);
    body.append("passphrase", this.state.restorePassphrase);
    if (this.state.installer) {
      if (!this.state.chosen) {
        this.setState({ error: "Choose the disk to install onto." });
        return;
      }
      if (this.state.confirm !== this.state.chosen) {
        this.setState({ error: `Type ${this.state.chosen} exactly to confirm the erase.` });
        return;
      }
      body.append("disk", this.state.chosen);
      body.append("confirm", this.state.confirm);
      body.append("wipe", this.state.wipe);
    }
    const res = await fetch("/submit-restore", { method: "POST", body });
    if (!res.ok) {
      let msg = "Restore failed — check the archive and passphrase, and retry.";
      try {
        msg = (await res.json()).error || msg;
      } catch {}
      this.setState({ error: msg });
      return;
    }
    // Same in-place wait as a typed submission: no optimistic page swap, the server's stage
    // moves the page when it actually does.
    this.setState({ submitting: true, error: "" });
    this.poll();
  };

  ack = async () => {
    await fetch("/handoff-ack", { method: "POST" });
    await this.loadState(); // the server drops out of the handoff stage; the view follows
  };

  // The rig role's whole form: where the pool is, what to call the machine, an optional
  // stratum password. No payout addresses (the Pithead holds those), no nodes, no dashboard
  // login — a rig has none of them.
  renderRigFields() {
    return renderRigFields(this);
  }

  // Restore-at-setup (#909): its own small card, reached by the toggle at the top of the
  // normal form and left by the "back" link here — independent of role/disk state, which
  // this branch handles on its own (the install target still needs picking on the medium).
  renderRestore() {
    return renderRestore(this);
  }

  renderSetup() {
    return renderSetup(this);
  }

  render() {
    const { stage, error, status } = this.state;
    let view;
    if (stage === "gate") view = html`<${Gate} error=${error} onSubmit=${this.auth} />`;
    else if (stage === "failed") view = failure.failedView(this);
    else if (stage === "installing") view = html`<${Installing} status=${status} />`;
    else if (stage === "done")
      view = html`<${Done} status=${status} handoff=${this.state.handoff}
        installer=${this.state.installer} stick=${this.state.chosen === "usb"}
        rig=${this.state.role === "rig"} onAck=${this.ack} />`;
    else view = savedRoleOrSetup(this);
    return html`<h1>Pithead setup</h1>${view}`;
  }
}

// Mount only in a browser (node --test imports this module; a bare `document` would break that).
// Clear #app: the shell ships the heading and "Loading…" inside it, and preact APPENDS (#1868).
if (typeof document !== "undefined") {
  document.getElementById("app").replaceChildren();
  render(html`<${WizardApp} />`, document.getElementById("app"));
}

export { Done, Gate, Installing, InstallSection, RestoreSection } from "./stages.mjs";
