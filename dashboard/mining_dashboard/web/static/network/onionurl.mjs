// The dashboard's Tor way in, rendered under the header's hostname/IP line (#1853).
//
// The server decides whether there IS one: state.dashboard_onion is {url, client_auth} only when
// the onion is both enabled and provisioned (mining_dashboard/web/views/header.py). This file
// infers nothing about that — no onion means no block at all, not an empty row, which is the
// difference between "Tor is off" and "Tor is broken".
//
// Both the Compose service and the appliance's podman quadlet pass DASHBOARD_ONION_ENABLED,
// _ADDRESS and _CLIENT_AUTH into the dashboard container (docker-compose.yml and
// lib/pithead/36-quadlet-units.sh). Neither path passes the client keys, and that has not changed:
// the one-time reveal below does not read an environment variable, it ASKS the host runner and the
// host hands one answer back through the read-only results leg (#1882).
//
// The URL is never elided. A v3 onion address is 56 characters of base32 with no redundancy, so a
// tidy-looking truncation produces a string that does not open — and the whole product here is
// that someone can copy it to a phone instead of reading it off a terminal.
//
// Reuses .brand-host (the host line's own size, spacing and overflow-wrap: anywhere), .text-muted,
// and the generic .btn-range control paired with .btn-reset, which is what supplies the 8px before
// the button (dashboard.css) — no header-only CSS is introduced.

import { Component, html } from "../app/preact.mjs";
import { pollResult } from "../config/configview.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
// The host answers this one out of .env with no daemon work, so it returns in a drain cycle, not
// in minutes the way backup does. A short ceiling keeps a stuck runner from looking like a hang.
const KEY_POLL_MAX = 30;
const KEY_TIMEOUT =
  "Stopped waiting for the client key. Check that the pithead-control unit is running, then try again.";

// POST the intent, then poll past the runner's interim status to a terminal result. Exported for
// node --test: this network flow is the logic, and OnionUrl only maps its outcome onto UI state.
export async function fetchClientKey() {
  const res = await fetch("/api/control/onion-client-key", {
    method: "POST",
    headers: CONTROL_HEADERS,
  });
  if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
  const { id } = await res.json();
  return await pollResult(id, "running", KEY_POLL_MAX, KEY_TIMEOUT);
}

// How long the copy confirmation stays up. It has to come down: the confirmation lives in a live
// region, and a live region announces a CHANGE to its content. A control that reads "Copied" from
// the first copy onwards announces once per page load and is silent for every copy after it.
export const CLEAR_MS = 4000;

// Copy `text`, answering true only if the clipboard actually took it. The clipboard is passed in
// rather than reached for: it is absent in the test renderer, and undefined on any page not
// served in a secure context — where the button has to degrade to "select it by hand" instead of
// throwing. A false answer leaves the label alone, so the operator is never told it copied when
// nothing reached the clipboard.
export async function copyText(text, clipboard) {
  try {
    if (!clipboard || typeof clipboard.writeText !== "function") return false;
    await clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

export class OnionUrl extends Component {
  constructor(props) {
    super(props);
    this.state = { copied: false, keyPhase: "idle", kit: null, keyError: null };
    this.clearTimer = null;
  }

  // The key is held in component state only, and only until the operator closes the card or
  // navigates away — the host has already nulled its own copy by then. There is no second fetch
  // of the SAME reveal; asking again mints a fresh window, which is the honest affordance.
  async showKey() {
    this.setState({ keyPhase: "loading", kit: null, keyError: null });
    try {
      const kit = await fetchClientKey();
      if (kit.status !== "applied") {
        this.setState({
          keyPhase: "idle",
          keyError: kit.error || "The host declined to show the client key.",
        });
        return;
      }
      this.setState({ keyPhase: "shown", kit });
    } catch (e) {
      this.setState({ keyPhase: "idle", keyError: e.message });
    }
  }

  componentWillUnmount() {
    clearTimeout(this.clearTimer);
  }

  async copy() {
    const ok = await copyText(this.props.onion.url, globalThis.navigator?.clipboard);
    // A copy that failed takes the standing confirmation down with it rather than leaving the
    // previous one to read as this one's answer.
    clearTimeout(this.clearTimer);
    this.setState({ copied: ok });
    if (ok) this.clearTimer = setTimeout(() => this.setState({ copied: false }), CLEAR_MS);
  }

  render({ onion }, { copied }) {
    if (!onion) return null;
    // The button's accessible name IS its text, so the confirmation cannot live in the label: one
    // copy would rename the control "Copied" — a state, not the action a returning reader needs.
    // It goes in a sibling status region instead, which is rendered EMPTY rather than conditionally,
    // because a live region inserted with its message already in it has no change to announce.
    return html`
      <div class="brand-host text-muted">
        <span class="font-mono">${onion.url}</span>
        <button type="button" class="btn-range btn-reset" onClick=${() => this.copy()}>
          Copy address
        </button>
        ${" "}
        <span role="status">${copied ? "Copied" : ""}</span>
        ${
          // Client authorisation on means the URL alone does not open — Tor Browser answers with
          // a generic failure that reads as "the onion is down". Saying so here is the whole
          // point; the key itself is host-side and never reaches this container.
          //
          // The ${" "} before the <span> is load-bearing and the repo has 13 other sites of it:
          // htm strips a whitespace run CONTAINING A NEWLINE from both ends of every static text
          // chunk, so a line break before a tag deletes the space and the words run together. A
          // field is pushed as its own child and never goes through that regex.
          onion.client_auth ? this.renderClientAuth() : null
        }
      </div>
    `;
  }

  // What the operator is told when the URL alone will not open. Which sentence is true depends on
  // whether this machine HAS a way to hand the key over: with the control channel on, the host
  // runner will, so the answer is a button on this page — which is the whole point on an appliance,
  // where the CLI verb the old wording named cannot be run at all (#1882). With it off there is no
  // runner to ask, and a shell on the host is the honest answer.
  renderClientAuth() {
    const { enabled } = this.props;
    const { keyPhase, kit, keyError } = this.state;
    return html`
      <div>
        Client authorisation is on — this address only opens for a browser holding your client
        key.${" "}
        ${
          enabled
            ? html`<button type="button" class="btn-range btn-reset"
                  disabled=${keyPhase === "loading"} onClick=${() => this.showKey()}>
                ${keyPhase === "loading" ? "Fetching…" : "Show client key"}
              </button>`
            : html`On a machine you can log in to,${" "}
              <span class="font-mono">pithead onion-client-key</span> prints it.`
        }
        ${keyError ? html`<div class="status-warn">${keyError}</div>` : null}
        ${keyPhase === "shown" && kit ? this.renderKit(kit) : null}
      </div>
    `;
  }

  // A genuine one-time reveal, worded as one: the host nulls its copy on its own timer, so "save
  // it now" is the only chance and not a suggestion. Both forms are shown because they are for
  // different Tor clients — Tor Browser prompts for the bare key, a system Tor/Orbot wants the
  // whole line in its ClientOnionAuthDir — and guessing which one the reader has is how they end
  // up pasting the wrong string into a prompt that just says "invalid".
  renderKit(kit) {
    return html`
      <div class="card">
        <h3>Tor client key</h3>
        <p class="status-warn">
          This is a PRIVATE key and is shown once — save it now. Anyone who has it can reach this
          dashboard's login over Tor.
        </p>
        <p class="text-muted text-xs">Tor Browser: paste just this key when it asks.</p>
        <p class="config-error-tail kit-passphrase font-mono">${kit.client_key}</p>
        <p class="text-muted text-xs">
          System Tor / Orbot: put this one line in your ClientOnionAuthDir.
        </p>
        <p class="config-error-tail font-mono">${kit.torrc_line}</p>
        <div class="config-actions">
          <button type="button" class="btn-toggle"
              onClick=${() => this.setState({ keyPhase: "idle", kit: null })}>
            I've saved it — close
          </button>
        </div>
      </div>
    `;
  }
}
