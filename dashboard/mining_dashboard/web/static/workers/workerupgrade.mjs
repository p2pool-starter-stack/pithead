// One-click rig upgrade (#597), and the control-result plumbing it shares with the config editor.
// Split out of workerview.mjs (#1877): that file stood at its line budget, and this is a whole
// behaviour on its own — a two-step arm → confirm, an in-flight flag a rebuild can hold for
// minutes, and a result line the config editor never reads. RigUpgrade owns that state. The poll
// helper, the control header and the status line stay beside it because both write paths — an
// apply and an upgrade — spool through the same /api/control/result endpoint and read it alike.

import { Component, html } from "../app/preact.mjs";
import { STATUS_META } from "../config/confighistory.mjs";

export const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const POLL_MS = 2000;
const POLL_MAX = 40; // ~80s — the host dials the rig then polls its /status
// ~5 min — covers spool latency + the host runner's own 90s rig-poll cap (#597). A rebuild that
// outlives the cap lands as "accepted"; the badge clears on its own once the rig reports the
// new version, so polling longer here buys nothing.
const UPGRADE_POLL_MAX = 150;

// Poll the shared control-result endpoint until a terminal outcome lands, skipping the interim
// "running". The apply can briefly out-run the dashboard, so tolerate a transient fetch failure.
export async function pollWorkerResult(id, max = POLL_MAX) {
  for (let i = 0; i < max; i++) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    let res;
    try {
      res = await fetch(`/api/control/result?id=${encodeURIComponent(id)}`);
    } catch {
      continue;
    }
    if (res.status === 202) continue;
    if (!res.ok) return { status: "error", error: `HTTP ${res.status}` };
    const out = await res.json();
    if (out.status && out.status !== "running") return out;
  }
  return { status: "pending", note: "still applying — reopen to see the outcome" };
}

export function StatusLine({ result }) {
  if (!result) return null;
  const meta = STATUS_META[result.status] || { cls: "text-muted", label: result.status };
  const detail = result.reason || result.error || result.note || "";
  return html`
    <p class=${"text-small mt-1 " + meta.cls} role="status" aria-live="polite">
        ${meta.label}${result.change_id ? html` · <span class="font-mono text-xs">${result.change_id}</span>` : null}
        ${detail ? html`<span class="text-muted"> — ${detail}</span>` : null}
    </p>`;
}

export class RigUpgrade extends Component {
  constructor(props) {
    super(props);
    // One-click rig upgrade (#597): a two-step arm → confirm, its own in-flight flag (a build
    // can run minutes) and its own result line, independent of the config editor's.
    this.state = { upgArmed: false, upgBusy: false, upgResult: null };
  }

  // One-click rig upgrade (#597). POSTs {worker, version} only — the version is the badge's
  // latest, a proposal the HOST re-derives and the rig bounds; this client never picks a target.
  // 202 means spooled: poll with the long budget (the rig may rebuild its miner, ~10 min).
  async upgrade() {
    const version = this.props.update.latest;
    this.setState({ upgArmed: false, upgBusy: true, upgResult: { status: "running" } });
    try {
      const res = await fetch("/api/control/worker-upgrade", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ worker: this.props.name, version }),
      });
      let out = await res.json();
      if (res.status === 202 && out.id) out = await pollWorkerResult(out.id, UPGRADE_POLL_MAX);
      this.setState({ upgBusy: false, upgResult: out });
      this.props.onDone(); // an applied upgrade clears the badge once the rig reports the new version
    } catch (e) {
      this.setState({ upgBusy: false, upgResult: { status: "error", error: String(e) } });
    }
  }

  render() {
    const { update, canEdit, busy } = this.props;
    const { upgArmed, upgBusy, upgResult } = this.state;
    return html`
        ${
          // This rig runs an older RigForge (#596) — the badge links to the release notes;
          // with the control channel on and an operator-set host, the one-click upgrade
          // button (#597) appears beside it: arm → confirm → POST → poll (a rig rebuild can
          // take ~10 min; the rig rolls back on a build that doesn't come back live).
          update && update.available && update.url
            ? html`<p class="mt-1"><a class="badge badge-accent" href=${update.url}
                        target="_blank" rel="noopener noreferrer"
                        title=${"A newer RigForge release is available: " + update.latest}
                     >New RigForge release ${update.latest} available ↗</a>${
                       canEdit && !upgBusy
                         ? upgArmed
                           ? html` <button class="btn-toggle" disabled=${busy}
                                 title=${"Ask the rig to upgrade itself to " + update.latest + " now"}
                                 onClick=${() => this.upgrade()}>Confirm upgrade</button>
                               <button class="btn-toggle" onClick=${() => this.setState({ upgArmed: false })}>Cancel</button>`
                           : html` <button class="btn-toggle" disabled=${busy}
                                 title="Upgrade this rig's RigForge to the latest release (its miner may rebuild, ~10 min)"
                                 onClick=${() => this.setState({ upgArmed: true, upgResult: null })}>Upgrade rig…</button>`
                         : null
}${
                       upgBusy
                         ? html` <span class="text-muted text-small">upgrading — a rebuild can take minutes…</span>`
                         : null
}</p>`
            : null
        }
        <${StatusLine} result=${upgResult} />`;
  }
}
