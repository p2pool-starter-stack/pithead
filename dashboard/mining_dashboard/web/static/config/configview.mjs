// Configuration view (#33): edit config.json from the dashboard, through the host-side control
// channel. Flow: GET /api/config (secrets masked) → form → POST /api/control/preview (the host
// runner dry-runs the candidate and returns the same change rows `pithead apply` prints) →
// confirm modal (destructive changes need a typed APPLY) → POST /api/control/commit → result.
// The view only ever ASKS — every request rides the X-Pithead-Control header (CSRF guard) and
// the host decides. When the channel is off the routes 404 and this view explains how to enable.
// The form and JSON pane edit one candidate. Core keys come from config.core-keys.json;
// other fields are grouped by logical section. The host's closed-schema gate validates both.
// Disabled form fields have no listener. Masked secrets stay unchanged when left blank.
import { Modal } from "../app/modal.mjs";
import { Component, createRef, html } from "../app/preact.mjs";
import { applyFailure, previewFailure, upgradeFailure } from "./applyfailure.mjs";
import { Field, validNumber } from "./configfield.mjs";
import {
  buildSections,
  editableCandidate,
  explicitCandidate,
  isSecretSentinel,
  jsonSyntaxError,
  markEditable,
  nestSection,
  parseConfigJson,
  regroupCore,
} from "./configlogic.mjs";
import { PreviewModal } from "./configpreview.mjs";
import { coerceForType, pathGet, pathSet } from "./configsync.mjs";
import { ConfigVersion } from "./configversion.mjs";
import { controlCommitResult, requirePreviewResponse } from "./controlclient.mjs";

export { editableCandidate, PreviewModal };

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const POLL_MS = 2000;
const POLL_MAX = 90; // 3 minutes — a commit recreates containers, which can take a while
// #1071: 45 minutes. The old 900s ceiling sat below image-pull bounds (60s release API, 900s bundle over Tor, 120s signature) and failed a healthy slow-circuit upgrade mid-pull.
// The pull itself is unbounded, so no constant is provably enough — the message below no longer claims the upgrade failed.
const UPGRADE_POLL_MAX = 1350;
// Poll /api/control/result until a terminal result lands; shared by the Configuration view, the
// Upgrade button (#59), and the Backup card (#908). `skip` ignores an intermediate status under
// the same id (the still-present "previewed" result while a commit runs; "running" while an
// upgrade or backup runs). Commit/upgrade/backup all briefly recreate or stop+restart the stack
// — commit/upgrade take the dashboard container itself down, backup takes the whole compose
// project down and back up — so a fetch here can transiently fail: a dropped connection (proxy down too, for backup) or a 502/503/504 (proxy up, upstream mid-restart, #622). Ride both out
// and keep polling until the result file answers.
export async function pollResult(id, skip, max = POLL_MAX, timeoutMessage) {
  for (let i = 0; i < max; i++) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    let res;
    try {
      res = await fetch(`/api/control/result?id=${encodeURIComponent(id)}`);
    } catch {
      continue;
    }
    if (res.status === 202) continue;
    // Both flows recreate the dashboard container itself; while it restarts, the reverse proxy
    // (caddy) stays up and answers 502/503/504 — the upstream is briefly gone, not failed. Ride
    // these out like a dropped connection (#59/#622); the durable control result is the real
    // outcome and `max` is the backstop. A real backend 500 (upstream up, erroring) still throws.
    if (res.status === 502 || res.status === 503 || res.status === 504) continue;
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const out = await res.json();
    if (out.status === skip) continue;
    return out;
  }
  // Stopping the wait is not the same as the work failing: the runner is a host unit that carries on
  // regardless of this page, and it records its own outcome. Saying "failed" here sent operators to
  // check a control channel that was healthy, and invited a re-click that only met the 10-minute
  // throttle. Say what is actually known instead.
  throw new Error(
    timeoutMessage ||
      "Stopped waiting — this can take longer than expected on a slow connection. The host keeps going and finishes on its own; reload in a few minutes to see the result. If the version is unchanged after that, check that dashboard.control is enabled and the pithead-control unit is running.",
  );
}

export class ConfigView extends Component {
  constructor(props) {
    super(props);
    this.state = {
      phase: "loading", // loading | disabled | form | previewing | confirm | committing | done | error
      cfg: null,
      sections: [],
      coreKeys: [],
      editableKeys: [], // #613: config paths the control gate will actually commit
      confirmKeys: [], // #719: config paths the gate commits behind a type-to-confirm
      approvalKeys: [],
      defaultKeys: [],
      lastApply: null,
      drafts: {}, // numeric fields' in-progress text, by config key (#3350)
      candidate: null, // the ONE config both the fields and the JSON pane edit (#785)
      pristine: "", // candidate's serialization at load — dirtiness is a comparison, not a flag
      editText: "",
      jsonError: null,
      preview: null,
      confirmText: "",
      payoutSuffixes: {},
      result: null,
      error: null,
    };
    this.modalRef = createRef();
  }
  componentDidMount() {
    this.load();
  }
  componentDidUpdate(_previousProps, { editText, pristine }) {
    const dirty = this.state.editText !== this.state.pristine;
    if (dirty !== (editText !== pristine)) this.props.onDirtyChange?.(dirty);
  }
  async load() {
    try {
      const res = await fetch("/api/config");
      if (res.status === 404) {
        this.setState({ phase: "disabled" });
        return;
      }
      await requirePreviewResponse(res);
      const cfg = await res.json();
      const candidate = editableCandidate(cfg);
      const text = JSON.stringify(candidate, null, 2);
      this.setState({
        phase: "form",
        cfg,
        sections: buildSections(candidate),
        coreKeys: cfg._core_keys || [],
        editableKeys: cfg._editable_keys || [],
        confirmKeys: cfg._confirm_keys || [],
        approvalKeys: cfg._approval_keys || [],
        defaultKeys: cfg._default_keys || [],
        lastApply: cfg._last_apply || null,
        candidate,
        drafts: {},
        pristine: text,
        editText: text,
        jsonError: null,
      });
    } catch (e) {
      this.setState({ phase: "error", error: String(e) });
    }
  }

  // Field -> candidate -> pane. The field's declared type drives coercion (shared
  // configsync.coerceForType), so a port stays a number and a toggle a boolean in the JSON.
  // A numeric field keeps the operator's text as a draft while they type (#3350): re-rendering
  // "0." or "-" from the coerced candidate rewrites the next keystroke. The candidate only takes
  // a draft that parses; otherwise it keeps its last valid number and the field is flagged.
  onFieldEdit(field, raw) {
    const { candidate, cfg } = this.state;
    if (field.type === "number") {
      const drafts = { ...this.state.drafts, [field.key]: raw };
      if (!validNumber(raw)) {
        this.setState({ drafts });
        return;
      }
      pathSet(candidate, field.key, coerceForType("number", raw));
      this.setState({
        drafts,
        candidate,
        editText: JSON.stringify(candidate, null, 2),
        jsonError: null,
      });
      return;
    }
    const value =
      field.type === "secret" && raw === ""
        ? pathGet(cfg, field.key)
        : coerceForType(field.type, raw);
    if (
      field.key === "tari.wallet_address" &&
      value !== pathGet(candidate, field.key) &&
      pathGet(candidate, "tari.spend_public_key") === pathGet(cfg, "tari.spend_public_key")
    ) {
      pathSet(candidate, "tari.spend_public_key", "");
    }
    pathSet(candidate, field.key, value);
    this.setState({ candidate, editText: JSON.stringify(candidate, null, 2), jsonError: null });
  }

  onJsonInput(text) {
    const err = jsonSyntaxError(text);
    if (err) {
      this.setState({ editText: text, jsonError: err });
      return;
    }
    const staged = parseConfigJson(text);
    if (staged.error) {
      this.setState({ editText: text, jsonError: staged.error });
      return;
    }
    const candidate = editableCandidate(staged.config);
    const editText =
      JSON.stringify(candidate) === JSON.stringify(staged.config)
        ? text
        : JSON.stringify(candidate, null, 2);
    // Keep invalid drafts (still being fixed) and valid ones whose number the pane left alone
    // (0.10 vs 0.1); drop a valid draft the pane changed, so the field follows it.
    const drafts = Object.fromEntries(
      Object.entries(this.state.drafts).filter(
        ([key, raw]) =>
          !validNumber(raw) || coerceForType("number", raw) === pathGet(candidate, key),
      ),
    );
    this.setState({ editText, jsonError: null, candidate, drafts });
  }
  onFilePick(e) {
    const file = e.target.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => this.onJsonInput(String(reader.result));
    reader.readAsText(file);
  }

  // Poll the result endpoint until a terminal result lands (shared pollResult above; kept as a
  // method because the view's flows and tests drive it through the instance).
  poll(id, skip) {
    return pollResult(id, skip);
  }

  // Keep explicit values; only read_config's untouched defaults were absent from config.json.
  buildProposed() {
    const { candidate, defaultKeys, jsonError, pristine } = this.state;
    if (jsonError) return { error: jsonError };
    return { config: explicitCandidate(JSON.parse(pristine || "{}"), candidate, defaultKeys) };
  }

  async save() {
    const staged = this.buildProposed();
    if (staged.error) {
      this.setState({ error: staged.error });
      return;
    }
    this.setState({ phase: "previewing", error: null });
    try {
      const proposed = staged.config;
      const res = await fetch("/api/control/preview", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ config: proposed }),
      });
      await requirePreviewResponse(res);
      let out = await res.json();
      if (out.status === "pending") out = { id: out.id, ...(await this.poll(out.id)) };
      if (out.status === "rejected") {
        this.setState({
          phase: "form",
          error: out.log ? { log: out.log } : out.error || "The host runner rejected the config.",
        });
        return;
      }
      this.setState({ phase: "confirm", preview: out, confirmText: "", payoutSuffixes: {} });
    } catch (e) {
      this.setState({ phase: "form", error: String(e) });
    }
  }

  async commit() {
    const id = this.state.preview.id;
    this.setState({ phase: "committing" });
    try {
      // #719: an in-scope disruptive change (preview.destructive) rides its typed confirmation to the host gate, which requires it before a CONFIRM row proceeds. Friction, not a secret.
      const body = { id };
      if (this.state.preview.destructive) body.confirm = this.state.confirmText;
      if (this.state.preview.approval_required) {
        body.approve = true;
        body.payout_suffixes = this.state.payoutSuffixes;
      }
      const opts = { method: "POST", headers: CONTROL_HEADERS, body: JSON.stringify(body) };
      let res = null; // #2366: a restart (#622) can drop this request or answer 502/503/504 — poll the id below
      try {
        res = await fetch("/api/control/commit", opts);
      } catch {}
      const restarting = !res || [502, 503, 504].includes(res.status);
      if (!restarting && !res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
      const out = restarting
        ? await this.poll(id, "previewed")
        : await controlCommitResult(res, id, this.poll.bind(this));
      const pristine = out.status === "applied" ? this.state.editText : this.state.pristine;
      this.setState({ phase: "done", result: out, pristine });
    } catch (e) {
      this.setState({ phase: "error", error: String(e) });
    }
  }

  // Form mode (#529): the core group (pinned, never collapsed) above the LOGICAL sections (#611),
  // each a native <details> — collapsed by default (no `open` attribute), which gets
  // keyboard/a11y toggling for free, the same "native platform feature over JS state" call
  // Worker Inspect's own <dialog> made (#518). Within a section, nestSection (#612) pulls a noisy
  // cluster (telegram.events, the notification sinks, healthchecks) into its own nested <details>,
  // one level deeper, also collapsed by default.
  renderForm(core, groups) {
    const { candidate, drafts } = this.state;
    const onEdit = (f, v) => this.onFieldEdit(f, v);
    // A set secret arrives as a sentinel and renders blank behind its keep-hint placeholder;
    // everything else shows the candidate's live value, so pane edits are visible immediately.
    const displayValue = (f) => {
      const v = pathGet(candidate, f.key);
      if (v === undefined || v === null || isSecretSentinel(v)) return f.value;
      return typeof v === "object" ? JSON.stringify(v) : String(v);
    };
    const field = (f, full) =>
      html`<${Field} field=${f} value=${f.key in drafts ? drafts[f.key] : displayValue(f)}
        invalid=${f.key in drafts && !validNumber(drafts[f.key])}
        full=${full} onEdit=${onEdit} />`;
    return html`<div class="grid">
        ${
          core.length
            ? html`<div class="card config-section config-section-core">
                <h2>Core</h2>
                ${core.map((f) => field(f, true))}
            </div>`
            : null
        }
        ${groups.map((s) => {
          const { fields, subgroups } = nestSection(s);
          // Computed on the flat fields AFTER nestSection, so a section that only mixes top-level
          // keys via its subgroups (Notifications: telegram + notifications + healthchecks, each
          // in its own labelled <details>) keeps short labels for the flat telegram.* remainder.
          const mixed = new Set(fields.map((f) => f.path[0])).size > 1;
          return html`<details class="card config-section">
              <summary>${s.name}</summary>
              ${s.description ? html`<p class="text-muted text-xs">${s.description}</p>` : null}
              ${fields.map((f) => field(f, mixed))}
              ${subgroups.map(
                (g) => html`<details class="config-subsection">
                    <summary>${g.label} (${g.fields.length})</summary>
                    ${g.fields.map((f) => field(f))}
                </details>`,
              )}
          </details>`;
        })}
    </div>`;
  }

  // The JSON pane (#785, the wizard's pattern): the whole candidate beneath the form, collapsed
  // by default, two-way live — never a separate mode. Load-from-file fills it (FileReader, no
  // upload); Save sends this candidate minus untouched reference defaults (#2365).
  renderJson(editText, jsonError, busy) {
    return html`<details class="card config-section">
        <summary><strong>Advanced</strong> — the configuration this page sends</summary>
        <p class="text-muted text-xs">Editing a field above updates it; editing here directly
        wins. Set secrets appear as <code>__secret__</code> markers and stay unchanged unless
        you replace them. A few developer settings are not shown here and are not changed by this page.</p>
        <textarea class="worker-edit" spellcheck="false" rows="20" disabled=${busy}
                  value=${editText} onInput=${(e) => this.onJsonInput(e.target.value)}></textarea>
        ${jsonError ? html`<p class="status-bad text-xs">${jsonError}</p>` : null}
        <div class="mt-1">
            <label class="text-muted text-xs">Load from file:
                <input type="file" accept="application/json,.json" disabled=${busy} onChange=${(e) => this.onFilePick(e)} />
            </label>
        </div>
    </details>`;
  }

  render() {
    const {
      phase,
      sections,
      coreKeys,
      editableKeys,
      confirmKeys,
      approvalKeys,
      defaultKeys,
      lastApply,
      editText,
      jsonError,
      preview,
      confirmText,
      payoutSuffixes,
      result,
      error,
    } = this.state;
    if (phase === "loading")
      return html`<div class="card"><p class="text-muted">Loading configuration…</p></div>`;
    if (phase === "disabled")
      return html`<div class="card">
          <h2>Configuration</h2>
          <p>The control channel is off (the default). Turning it on lets you edit the
          configuration, create backups, and run diagnostics, and requires a dashboard login —
          see the${" "}<a href="https://github.com/p2pool-starter-stack/pithead/blob/main/docs/dashboard.md#configuration-view" target="_blank" rel="noopener noreferrer">Configuration view guide</a>.</p>
          <p class="text-muted text-xs">Setting:${" "}<code>dashboard.control.enabled</code></p>
      </div>`;
    if (phase === "error") {
      return html`<div class="card">
          <h2>Configuration</h2>
          <p class="status-bad">${error}</p>
          ${this.state.candidate ? html`<button class="btn-toggle" onClick=${() => this.setState({ phase: "form", preview: null, error: null })}>Back to the form</button>` : null}
          <button class="btn-toggle" onClick=${() => this.load()}>${this.state.candidate ? "Discard draft and reload from host" : "Reload"}</button>
      </div>`;
    }
    if (phase === "done") {
      const ok = result.status === "applied";
      return html`<div class="card">
          <h2>Configuration</h2>
          <div role="status" aria-live="polite">${
            ok
              ? html`<p class="status-ok">Changes applied — only the affected containers were recreated.</p>`
              : applyFailure(result, this.props.appliance)
          }</div>
          <button class="btn-toggle" onClick=${() => (ok ? this.load() : this.setState({ phase: "form", result: null }))}>Back to the form</button>
          ${ok ? null : html`<button class="btn-toggle" onClick=${() => this.load()}>Discard draft and reload from host</button>`}
      </div>`;
    }
    const busy = phase === "previewing" || phase === "committing";
    const dirty = editText !== this.state.pristine;
    const badDraft = Object.values(this.state.drafts).some((raw) => !validNumber(raw));
    const canSave = dirty && !jsonError && !badDraft;
    const { core, sections: groups } = regroupCore(
      markEditable(sections, editableKeys, confirmKeys, approvalKeys, defaultKeys),
      coreKeys,
    );
    return html`<div class="config-view">
        <${ConfigVersion} cfg=${this.state.cfg} />
        ${error ? previewFailure(error, this.props.appliance) : null}
        ${
          lastApply?.status === "failed"
            ? html`<div class="card"><p class="status-bad">The last apply failed. This form shows
              the desired configuration; services that stayed running may still use the earlier settings.</p></div>`
            : null
        }
        ${
          this.state.cfg?.ssh
            ? html`<div class="card"><p class="status-warn">SSH settings from an older configuration are ignored and are not saved from this page.</p></div>`
            : null
        }
        ${this.renderForm(core, groups)}
        ${this.renderJson(editText, jsonError, busy)}
        <div class="config-actions">
            <button class="btn-toggle active" disabled=${!canSave || busy} onClick=${() => this.save()}>${phase === "previewing" ? "Previewing…" : "Save & preview changes"}</button>
            ${dirty ? html`<button class="btn-toggle" disabled=${busy} onClick=${() => this.load()}>Discard edits</button>` : null}
        </div>
        <p class="sr-only" role="status" aria-live="polite">${phase === "previewing" ? "Previewing changes…" : ""}</p>
        ${
          this.props.active !== false && (phase === "confirm" || phase === "committing")
            ? html`<${PreviewModal} modalRef=${this.modalRef} preview=${preview} confirmText=${confirmText}
                  onConfirmText=${(t) => this.setState({ confirmText: t })}
                  payoutSuffixes=${payoutSuffixes}
                  onPayoutSuffix=${(chain, value) =>
                    this.setState({
                      payoutSuffixes: { ...this.state.payoutSuffixes, [chain]: value },
                    })}
                  onConfirm=${() => this.commit()}
                  onCancel=${() => this.modalRef.current?.close()}
                  onClose=${() => this.setState({ phase: "form", preview: null })}
                  busy=${phase === "committing"} />`
            : null
        }
    </div>`;
  }
}

// --- One-click upgrade (#59) ---------------------------------------------------------

// POST the upgrade intent, then wait out the whole run. Exported for node --test — this network
// flow is the logic; UpgradeControl only maps its outcome onto UI state. The server answers 202
// straight away, so the real outcome arrives via pollResult, skipping "running" and the restart.
export async function runUpgrade(version) {
  const res = await fetch("/api/control/upgrade", {
    method: "POST",
    headers: CONTROL_HEADERS,
    body: JSON.stringify({ version }),
  });
  if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
  const out = await res.json();
  return pollResult(out.id, "running", UPGRADE_POLL_MAX);
}

// Header control for #59, rendered next to the new-release badge only when the server reports
// BOTH a newer release and an enabled control channel. The typed UPGRADE confirm is UX, not a
// security control — the host runner re-derives the target from the GitHub release API and
// refuses anything that isn't the latest published release.
export class UpgradeControl extends Component {
  constructor(props) {
    super(props);
    // idle | confirm | upgrading | done | failed
    this.state = { phase: "idle", confirmText: "", result: null };
    this.modalRef = createRef();
  }
  // Upgrading is the one phase with no way back — a no-op; its body says so.
  cancel() {
    if (this.state.phase === "upgrading") return;
    this.modalRef.current?.close();
  }
  async run() {
    this.setState({ phase: "upgrading" });
    try {
      const out = await runUpgrade(this.props.update.latest);
      this.setState({ phase: out.status === "upgraded" ? "done" : "failed", result: out });
    } catch (e) {
      this.setState({ phase: "failed", result: { error: String(e) } });
    }
  }

  render() {
    const { update, enabled } = this.props;
    const { phase, confirmText, result } = this.state;
    const available = enabled && update && update.available;
    if (!available && phase !== "failed") return null;
    const version = update?.latest;
    const onClose = () => this.setState({ phase: "idle", confirmText: "" });
    let modal = null;
    if (phase === "confirm") {
      modal = html`<${Modal} ref=${this.modalRef} title=${"Upgrade to " + version}
          onCancel=${() => this.cancel()} onClose=${onClose}>
              <p>The host pulls the ${version} release and recreates every container — including
              this dashboard, which goes away for a moment, and the miners' stratum connection,
              which reconnects. Your config, wallet, and chain data are kept.</p>
              <label class="config-confirm-type">Type <code>UPGRADE</code> to confirm:
                  <input type="text" value=${confirmText}
                      onInput=${(e) => this.setState({ confirmText: e.target.value })} /></label>
              <div class="config-modal-actions">
                  <button class="btn-toggle" onClick=${() => this.cancel()}>Cancel</button>
                  <button class="btn-toggle active" disabled=${confirmText !== "UPGRADE"}
                      onClick=${() => this.run()}>Upgrade</button>
              </div>
      </${Modal}>`;
    } else if (phase === "upgrading") {
      modal = html`<${Modal} ref=${this.modalRef} title=${"Upgrading to " + version + "…"}
          onCancel=${() => this.cancel()} onClose=${onClose}>
              <p class="text-muted">The host is pulling images and recreating containers — this can't
              be interrupted. This page will briefly disconnect while the dashboard restarts — leave
              it open; it reports the outcome when the new version is up.</p>
      </${Modal}>`;
    } else if (phase === "done") {
      modal = html`<${Modal} ref=${this.modalRef} title=${"Upgraded to " + (result.version || version)}
          onCancel=${() => this.cancel()} onClose=${onClose}>
              <p class="status-ok">The stack is running the new release.</p>
              ${
                result.rollback
                  ? html`<p class="text-muted">The previous release is kept at <code>${result.rollback}</code>
                    on the host — the rollback copy if this version misbehaves.</p>`
                  : null
              }
              <div class="config-modal-actions">
                  <button class="btn-toggle active" onClick=${() => window.location.reload()}>Reload the dashboard</button>
              </div>
      </${Modal}>`;
    } else if (phase === "failed") {
      modal = html`<${Modal} ref=${this.modalRef} title="Upgrade did not complete"
          onCancel=${() => this.cancel()} onClose=${onClose}>
              ${upgradeFailure(result, this.props.appliance)}
              <div class="config-modal-actions">
                  <button class="btn-toggle" onClick=${() => this.cancel()}>Close</button>
              </div>
      </${Modal}>`;
    }
    return [
      available
        ? html`<button class="badge badge-accent version-badge ml-2"
              title=${"Upgrade the stack to " + version + " from the dashboard"}
              onClick=${() => this.setState({ phase: "confirm", confirmText: "" })}>
              Upgrade to ${version}
          </button>`
        : null,
      modal,
    ];
  }
}
