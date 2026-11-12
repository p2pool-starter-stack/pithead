// Support bundle card (#4036): collect the redacted diagnostics archive the support verb
// produces, and hand it to the browser as a download — for a machine whose operator has no
// shell. The host does all the work: it picks its own units, clamps the window, redacts every
// line through the one redactor, caps its own size, and only then lands the archive in the
// results spool where the download route streams it for exactly the id whose result says
// applied. Nothing here reads archive contents.

import { Component, html } from "../app/preact.mjs";
import { pollResult } from "../config/configview.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const BUNDLE_POLL_MAX = 450;
const BUNDLE_TIMEOUT =
  "Stopped waiting for the support bundle. The host keeps collecting, but this dashboard did not return; reload, then collect again only after the earlier request has finished.";

export const DEFAULT_HOURS = 72;

export async function runSupportBundle(hours) {
  const body = hours ? { hours } : {};
  const res = await fetch("/api/control/support-bundle", {
    method: "POST",
    headers: CONTROL_HEADERS,
    body: JSON.stringify(body),
  });
  if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
  const { id } = await res.json();
  const result = await pollResult(id, "running", BUNDLE_POLL_MAX, BUNDLE_TIMEOUT);
  return { id, ...result };
}

export function bundleHref(id) {
  return `/api/control/support-bundle-download?id=${encodeURIComponent(id)}`;
}

export class SupportBundlePanel extends Component {
  constructor(props) {
    super(props);
    this.state = { phase: "idle", hours: DEFAULT_HOURS, id: null, result: null };
  }

  async run() {
    this.setState({ phase: "collecting" });
    try {
      const out = await runSupportBundle(this.state.hours);
      this.setState({
        id: out.id,
        result: out,
        phase: out.status === "applied" ? "ready" : "failed",
      });
    } catch (e) {
      this.setState({ phase: "failed", result: { error: String(e) } });
    }
  }

  render() {
    if (!this.props.enabled) {
      return html`<div class="card">
          <h2>Support bundle</h2>
          <p>The support bundle is off with the rest of the control channel — see
          Configuration.</p>
      </div>`;
    }
    const { phase, id, result } = this.state;
    if (phase === "ready" && result) {
      return html`<div class="card">
          <h2>Support bundle ready</h2>
          <p class="text-muted text-xs">Archive: <span class="font-mono">${result.archive}</span>
          — journal of the last ${result.hours} hours, redacted on the host before it was
          written.</p>
          <p class="text-muted text-xs">The download stays available for about an hour; after
          that, collect a fresh bundle.</p>
          <div class="config-actions">
              <a class="btn-toggle active" href=${bundleHref(id)} target="_blank"
                 rel="noopener noreferrer">Download bundle</a>
              <button class="btn-toggle" onClick=${() =>
                this.setState({ phase: "idle", id: null, result: null })}>Done</button>
          </div>
      </div>`;
    }
    if (phase === "failed") {
      return html`<div class="card">
          <h2>Support bundle</h2>
          <p class="status-bad">${(result && result.error) || "The host did not complete the bundle."}</p>
          <button class="btn-toggle" onClick=${() =>
            this.setState({ phase: "idle", result: null })}>Close</button>
      </div>`;
    }
    return html`<div class="card">
        <h2>Support bundle</h2>
        <p>Collect one redacted archive for a bug report: recent logs from every Pithead
        service and container, dashboard health history, Tor bootstrap state, versions and the
        RAUC slot, and the configuration's key shape. Values — passwords, wallet addresses,
        tokens, onion addresses — are removed on the host before the archive is written.
        Nothing leaves the box until you download it.</p>
        <label class="text-muted text-xs">Journal window (hours)
            <input class="btn-toggle" type="number" min="1" max="168" value=${this.state.hours}
                   disabled=${phase === "collecting"}
                   onInput=${(e) => this.setState({ hours: Number(e.target.value) || 0 })} />
        </label>${" "}
        <button class="btn-toggle active" disabled=${phase === "collecting"}
                onClick=${() => this.run()}>${phase === "collecting"
                  ? "Collecting…"
                  : "Collect support bundle"}</button>
    </div>`;
  }
}
