import { Component, html } from "../app/preact.mjs";
import { PAGES, routeUrl, SECTIONS } from "./navigation.mjs";
import { profileBadge, stackStatus } from "./status.mjs";

export class AdvancedDrawer extends Component {
  constructor(props) {
    super(props);
    this.state = { search: "" };
    this.dialog = null;
    this.visited = new Set();
  }
  componentDidMount() {
    this.syncDialog();
  }
  componentDidUpdate(previous) {
    this.syncDialog();
    if (previous.section !== this.props.section && this.props.section)
      this.dialog?.querySelector("h3")?.focus();
  }
  syncDialog() {
    if (this.props.section && !this.dialog.open) this.dialog.showModal();
    if (!this.props.section && this.dialog.open) this.dialog.close();
  }
  render({ section, onSection, onClose, theme, onTheme, renderSection }) {
    if (section) this.visited.add(section);
    const query = this.state.search.trim().toLowerCase();
    const matches = Object.entries(SECTIONS).filter(([key, label]) =>
      `${key} ${label}`.toLowerCase().includes(query),
    );
    return html`<dialog class="advanced" aria-label="Advanced"
      ref=${(node) => {
        this.dialog = node;
      }}
      onCancel=${(event) => {
        event.preventDefault();
        onClose();
      }}>
      <div class="drawer-header"><h2 id="advanced-title">Advanced</h2>
        <button type="button" onClick=${onClose} aria-label="Close Advanced">Close</button></div>
      <label class="drawer-search">Find a section or setting
        <input type="search" value=${this.state.search} placeholder="Search labels or key names"
          onInput=${(event) => this.setState({ search: event.target.value })} /></label>
      <nav class="drawer-sections" aria-label="Advanced sections">
        ${matches.map(
          ([key, label]) => html`<a href=${`?advanced=${key}`}
          aria-current=${section === key ? "location" : null}
          onClick=${(event) => {
            event.preventDefault();
            onSection(key);
          }}>${label}</a>`,
        )}
      </nav>
      ${!matches.length ? html`<p role="status">No matching section. Setting keys appear when their owning page is available.</p>` : null}
      <section aria-label=${SECTIONS[section] || "Advanced section"}>
        <h3 tabindex="-1">${SECTIONS[section] || "Advanced"}</h3>
        ${
          section === "appearance"
            ? html`<label for="sovereign-theme">Theme</label><select id="sovereign-theme" value=${theme} onChange=${(event) => onTheme(event.target.value)}>
              <option value="auto">Follow operating system</option><option value="light">Light</option><option value="dark">Dark</option>
            </select>`
            : null
        }
        ${[...this.visited]
          .filter((key) => key !== "appearance")
          .map(
            (key) => html`<div key=${key} hidden=${key !== section}>
          ${renderSection?.(key) || html`<p>This section is being built for the new interface. Continue using the current dashboard until cutover.</p>`}
        </div>`,
          )}
      </section>
    </dialog>`;
  }
}

export function Shell({
  route,
  url,
  state,
  connected,
  sessionExpired,
  theme,
  onTheme,
  onNavigate,
  onRetry,
  renderPage,
  renderSection,
}) {
  const status = stackStatus(state, connected);
  const link = (page, section = null) => routeUrl(url, page, section).href;
  const navigate =
    (page, section = null) =>
    (event) => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
        return;
      event.preventDefault();
      onNavigate(page, section);
    };
  return html`<a class="skip-link" href="#page-title">Skip to content</a>
    <div class="shell">
      <aside class="sidebar" aria-label="Stack navigation">
        <div class="brand"><img src="/static/pithead-mark.svg" alt="" />Pithead</div>
        <span>${state?.version?.text || "Version not reported"}</span>
        <a href=${link("machines")} onClick=${navigate("machines")}>Server · address hidden</a>
        <a class=${`status-chip status-${status.level}`} href=${link("overview")} onClick=${navigate("overview")}>${status.text}</a>
        <span>${profileBadge(state?.profile)}</span>
        <nav aria-label="Main navigation">${Object.entries(PAGES).map(
          ([
            key,
            [label],
          ]) => html`<a href=${link(key)} aria-current=${route.page === key ? "page" : null}
            onClick=${navigate(key)}>${label}</a>`,
        )}
          <button class="advanced-opener" type="button" aria-haspopup="dialog" aria-expanded=${!!route.advanced}
            onClick=${() => onNavigate(route.page, PAGES[route.page][2])}>Advanced</button>
        </nav>
        ${state?.update?.available ? html`<a class="update-link" href=${link("settings", "update-details")} onClick=${navigate("settings", "update-details")}>Update available</a>` : null}
      </aside>
      <div class="workspace">
        <p class="preview-note">Development preview — page content is still being built. <a href="/">Current dashboard</a></p>
        <p class="muted" aria-live="polite">Last snapshot: ${state?.last_update || "not received"}${!connected && state ? " · stale" : ""}</p>
        ${
          !connected
            ? html`<div class="notice" role="alert">
          <p>${sessionExpired ? "Session expired. Sign in again to reconnect." : "Disconnected. Keeping the last successful snapshot; its values may have changed."}</p>
          <button type="button" onClick=${onRetry}>Retry connection</button>
          ${sessionExpired ? html`<a href=${url}>Sign in again</a>` : null}
        </div>`
            : null
        }
        <main id="page-content">
          <header class="page-header"><h1 id="page-title" tabindex="-1">${PAGES[route.page][0]}</h1><p>${PAGES[route.page][1]}</p></header>
          <div class="route-announcement" aria-live="polite">${PAGES[route.page][0]}</div>
          ${Object.keys(PAGES).map(
            (page) => html`<div key=${page} hidden=${route.page !== page}>
            ${renderPage?.(page, state) || html`<p class="panel">This page is being built for the new interface. Continue using the current dashboard until cutover.</p>`}
          </div>`,
          )}
        </main>
      </div>
    </div>
    <${AdvancedDrawer} section=${route.advanced} theme=${theme} onTheme=${onTheme}
      onSection=${(section) => onNavigate(route.page, section)}
      onClose=${() => onNavigate(route.page)} renderSection=${renderSection} />`;
}
