import { Component, createRef, html } from "../app/preact.mjs";
import { ThemeSwitcher, VersionBadge } from "../app/ui.mjs";
import { OsVerdictBanner } from "../system/osupdate.mjs";
import { SyncView } from "../system/syncview.mjs";
import { WorkerInspect } from "../workers/workerview.mjs";
import { ICONS, miningStatus, PAGES, routePage } from "./navigation.mjs";
import { SovereignOverview } from "./overview.mjs";
import { PageContent, SettingsPage } from "./pages.mjs";

function Icon({ page }) {
  return html`<svg width="21" height="21" viewBox="0 0 24 24" fill="none"
    stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"
    aria-hidden="true"><path d=${ICONS[page]} /></svg>`;
}

export class SovereignApp extends Component {
  constructor(props) {
    super(props);
    const page = routePage(globalThis.location?.hash || "", props.ui.view);
    this.state = { page, settingsVisited: page === "settings" };
    this.heading = createRef();
    this.onRoute = () => {
      if (globalThis.location?.hash === "#sovereign-main") return;
      const next = routePage(globalThis.location?.hash || "", this.props.ui.view);
      this.setState({
        page: next,
        settingsVisited: this.state.settingsVisited || next === "settings",
      });
    };
    this.navigate = (page) => {
      globalThis.location.hash = routePage(`#${page}`);
    };
  }
  componentDidMount() {
    globalThis.addEventListener("hashchange", this.onRoute);
  }
  componentDidUpdate(_prevProps, prevState) {
    if (prevState.page !== this.state.page) this.heading.current?.focus();
  }
  componentWillUnmount() {
    globalThis.removeEventListener("hashchange", this.onRoute);
  }
  render() {
    const { state, connected, ui, onTheme, onCloseInspect, onRetry } = this.props;
    const { page, settingsVisited } = this.state;
    const [, title, subtitle] = PAGES.find(([id]) => id === page);
    const status = miningStatus(state, connected);
    const props = { ...this.props, onView: this.navigate };
    const nav = ([id, label]) => html`<a href=${`#${id}`} class=${page === id ? "is-current" : ""}
      aria-current=${page === id ? "page" : null}><${Icon} page=${id} /><span>${label}</span>
      ${id === "machines" && state ? html`<span class="sov-nav-count">${state.workers?.length || 0}</span>` : null}</a>`;
    return html`<div class="sovereign">
      <a class="sov-skip" href="#sovereign-main">Skip to content</a>
      <aside class="sov-sidebar" aria-label="Pithead">
        <a class="sov-brand" href="#overview" aria-label="Pithead overview">
          <img src="/static/pithead-mark.svg" alt="" width="76" height="76" />
          <span>Pithead</span><small>MONERO MINING</small>
        </a>
        <nav class="sov-nav" aria-label="Main navigation">${PAGES.slice(0, 5).map(nav)}</nav>
        <nav class="sov-nav sov-nav-bottom" aria-label="Administration">${PAGES.slice(5).map(nav)}</nav>
        <div class="sov-edition"><span>01 / SOVEREIGN</span><span>EARLY PREVIEW</span></div>
      </aside>
      <div class="sov-workspace">
        <header class="sov-topbar">
          <span class="sov-eyebrow">YOUR CORNER OF THE NETWORK</span>
          <div class="sov-live"><span class=${`sov-status c-${status.tone}`}>${status.label}</span>
            <span class="sov-freshness">${state ? `Snapshot · ${state.last_update}` : "Awaiting first snapshot"}</span>
          </div>
          <${ThemeSwitcher} theme=${ui.theme} onTheme=${onTheme} />
        </header>
        <main id="sovereign-main" class="sov-main mode-advanced" tabindex="-1">
          <div class="sr-only" role="status" aria-live="polite">${title}</div>
          ${
            !connected
              ? html`<div class="disconnected-banner" role="status">Disconnected — ${state ? `showing the last snapshot from ${state.last_update}.` : "no snapshot available."}
            <button type="button" class="btn-toggle" onClick=${onRetry}>Retry now</button></div>`
              : null
          }
          ${state ? html`<${OsVerdictBanner} os=${state.os_update} />` : null}
          <div class=${page === "overview" ? "sov-route-heading sr-only" : "sov-page-heading"}>
            <h1 ref=${this.heading} tabindex="-1">${title}</h1><p>${subtitle}</p>
          </div>
          ${
            !state
              ? html`<div class="sov-loading"><img src="/static/pithead-mark.svg" alt="" width="64" height="64" /><h2>Connecting to your operation</h2><p>Waiting for the dashboard. Your node may still be starting.</p></div>`
              : state.syncing && page === "overview"
                ? html`<${SyncView} sync=${state.sync} />`
                : page === "settings"
                  ? null
                  : page === "overview"
                    ? html`<${SovereignOverview} ...${props} />`
                    : html`<${PageContent} key=${page} page=${page} ...${props} />`
          }
          ${
            state && settingsVisited
              ? html`<section hidden=${page !== "settings"} aria-label="Configuration editor">
            <${SettingsPage} state=${state} /></section>`
              : null
          }
        </main>
        <footer class="sov-footer"><span>YOUR HARDWARE. YOUR HASHRATE. YOUR RULES.</span>
          <${VersionBadge} version=${state?.version} /><a href="/">Classic dashboard</a></footer>
      </div>
      ${
        state?.control_enabled && ui.inspectWorker
          ? html`<${WorkerInspect} name=${ui.inspectWorker}
        onClose=${onCloseInspect} key=${ui.inspectWorker} />`
          : null
      }
    </div>`;
  }
}
