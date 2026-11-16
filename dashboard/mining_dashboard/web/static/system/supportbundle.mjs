import { Component, html } from "../app/preact.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const POLL_MS = 2000;
const BUNDLE_POLL_MAX = 450;
const RANGE_POLL_MAX = 15;
const BUNDLE_TIMEOUT =
  "Stopped waiting for the support bundle. The host keeps collecting, but this dashboard did not return; reload, then export again only after the earlier request has finished.";

export const DEFAULT_HOURS = 72;
export const PRESETS = [
  { hours: 1, label: "Last 1 hour" },
  { hours: 6, label: "Last 6 hours" },
  { hours: 24, label: "Last 24 hours" },
  { hours: 72, label: "Last 72 hours" },
  { hours: 168, label: "Last 7 days" },
];

const stripMs = (d) => d.toISOString().replace(/\.\d{3}Z$/, "Z");
const shown = (iso) => String(iso).replace("T", " ").replace("Z", " UTC");

export function requestWindow({ preset, since, until }, now = new Date()) {
  if (preset !== "custom") return { body: { hours: preset } };
  const start = new Date(since);
  const end = new Date(until);
  if (!since || !until || Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) {
    return { error: "Invalid range: choose both a start and an end time." };
  }
  if (start >= end) return { error: "Invalid range: the start must be before the end." };
  if (end > now) return { error: "Invalid range: the end cannot be in the future." };
  return { body: { since: stripMs(start), until: stripMs(end) } };
}

export function reachNote(oldest, body, now = new Date()) {
  if (!oldest || !(body.since || body.hours)) return null;
  const from = body.since ? new Date(body.since) : new Date(now.getTime() - body.hours * 3600000);
  if (from >= new Date(oldest)) return null;
  return `The logs on this system only reach back to ${shown(oldest)}. The bundle will start there.`;
}

async function pollSupport(id, max, timeoutMessage) {
  for (let i = 0; i < max; i++) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    let res;
    try {
      res = await fetch(`/api/control/support-bundle-result?id=${encodeURIComponent(id)}`);
    } catch {
      continue;
    }
    if (res.status === 202 || [502, 503, 504].includes(res.status)) continue;
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const out = await res.json();
    if (out.status === "running") continue;
    return out;
  }
  throw new Error(timeoutMessage);
}

async function submit(path, body) {
  const res = await fetch(path, {
    method: "POST",
    headers: CONTROL_HEADERS,
    body: JSON.stringify(body),
  });
  if (res.status === 400) {
    throw new Error(`Invalid range: ${(await res.text()).trim() || "the request was refused."}`);
  }
  if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
  return (await res.json()).id;
}

export async function runSupportBundle(body) {
  const id = await submit("/api/control/support-bundle", body);
  const result = await pollSupport(id, BUNDLE_POLL_MAX, BUNDLE_TIMEOUT);
  return { id, ...result };
}

export async function fetchOldest() {
  const id = await submit("/api/control/support-bundle-range", {});
  const result = await pollSupport(id, RANGE_POLL_MAX, "");
  return result.status === "applied" ? result.oldest || null : null;
}

export function bundleHref(id) {
  return `/api/control/support-bundle-download?id=${encodeURIComponent(id)}`;
}

export async function downloadBundle(id, name) {
  const res = await fetch(bundleHref(id));
  if (!res.ok) {
    throw new Error(
      `The bundle was collected but the download is unavailable (HTTP ${res.status}). It is kept for about an hour; export again.`,
    );
  }
  const url = URL.createObjectURL(await res.blob());
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

export class SupportBundlePanel extends Component {
  constructor(props) {
    super(props);
    this.state = {
      phase: "idle",
      preset: DEFAULT_HOURS,
      since: "",
      until: "",
      oldest: null,
      id: null,
      result: null,
      error: null,
    };
  }

  componentDidMount() {
    fetchOldest()
      .then((oldest) => this.setState({ oldest }))
      .catch(() => {});
  }

  async run() {
    const win = requestWindow(this.state);
    if (win.error) {
      this.setState({ phase: "failed", error: win.error });
      return;
    }
    this.setState({ phase: "collecting", error: null, result: null });
    try {
      const out = await runSupportBundle(win.body);
      if (out.status !== "applied") {
        this.setState({
          phase: "failed",
          error: out.error || "The host did not complete the bundle.",
        });
        return;
      }
      this.setState({ id: out.id, result: out });
      await downloadBundle(out.id, out.archive);
      this.setState({ phase: "done" });
    } catch (e) {
      this.setState({ phase: "failed", error: e.message || String(e) });
    }
  }

  render() {
    const { phase, preset, oldest, id, result, error } = this.state;
    const busy = phase === "collecting";
    const note = reachNote(oldest, requestWindow(this.state).body || {});
    return html`<div class="card">
        <h2>Export logs</h2>
        <p>Collect one redacted zip of the system journal for a bug report: every Pithead
        service and container, the kernel log, the boot list, dashboard health history, versions
        and the configuration's key shape. Passwords, wallet addresses, tokens and onion
        addresses are removed on the host before the zip is written. Nothing leaves the box
        until the download starts.</p>
        <p class="text-muted text-xs">${
          oldest
            ? `Logs on this system reach back to ${shown(oldest)}.`
            : "How far back the logs reach is not known yet."
        }</p>
        <label class="text-muted text-xs">Time frame
            <select class="btn-toggle" disabled=${busy} value=${preset}
                    onChange=${(e) =>
                      this.setState({
                        preset: e.target.value === "custom" ? "custom" : Number(e.target.value),
                      })}>
                ${PRESETS.map(
                  (p) =>
                    html`<option value=${p.hours} selected=${preset === p.hours}>${p.label}</option>`,
                )}
                <option value="custom" selected=${preset === "custom"}>Custom range</option>
            </select>
        </label>
        ${
          preset === "custom"
            ? html` <label class="text-muted text-xs">Start
                  <input class="btn-toggle" type="datetime-local" name="since" disabled=${busy}
                         value=${this.state.since}
                         onInput=${(e) => this.setState({ since: e.target.value })} />
              </label>
              <label class="text-muted text-xs">End
                  <input class="btn-toggle" type="datetime-local" name="until" disabled=${busy}
                         value=${this.state.until}
                         onInput=${(e) => this.setState({ until: e.target.value })} />
              </label>
              <p class="text-muted text-xs">Custom times are in this browser's time zone.</p>`
            : null
        }
        ${note ? html`<p class="text-muted text-xs" role="note">${note}</p>` : null}
        <div class="config-actions">
            <button class="btn-toggle active" disabled=${busy} onClick=${() => this.run()}>${
              busy ? "Collecting…" : "Export logs"
            }</button>
        </div>
        ${busy ? html`<p class="text-muted text-xs" role="status">Collecting on the host — this can take a few minutes. The download starts by itself when it is ready.</p>` : null}
        ${error ? html`<p class="status-bad" role="alert">${error}</p>` : null}
        ${
          phase === "done" && result
            ? html`<p class="text-muted text-xs" role="status">Downloaded
              <span class="font-mono">${result.archive}</span> — window
              ${shown(result.effective_since || result.since)} to
              ${shown(result.effective_until || result.until)}${
                result.journal_short
                  ? ", shorter than you asked: the logs do not reach back further"
                  : ""
              }. <a href=${bundleHref(id)} download=${result.archive}>Download again</a> (kept for about an hour).</p>`
            : null
        }
    </div>`;
  }
}
