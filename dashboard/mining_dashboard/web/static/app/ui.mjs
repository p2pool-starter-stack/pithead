import { heroKpis, THEME_LABELS, THEME_ORDER } from "./logic.mjs";
import { html } from "./preact.mjs";

// Palette token -> text-colour class (defined in dashboard.css).
const cVar = (v) => "c-" + v;

// --- Small shared pieces -------------------------------------------------------------

// Sign colour for a net figure — the one judgment colour in the calculator: green when the
// operation profits, red when it loses. Everything that is a plain estimate stays accent/plain.
const netCls = (v) => (v !== null && Number.isFinite(v) && v < 0 ? "c-bad" : "c-ok");

const SharesStat = ({ sw, label = "Share in Window" }) => html`
    <div class="stat-card">
        <h5>${label}</h5>
        <p><span class=${sw.ok ? "status-ok" : "status-bad"}>${sw.count}</span></p>
    </div>`;

const Badges = ({ badges }) => html`
    <div class="badge-row">
        ${badges.map(
          (b) => html`
            <span class=${"badge badge-" + b.variant} title=${b.title || ""}>${b.text}</span>`,
        )}
    </div>`;

// Build-version badge (Issue #58). Muted badge-outline so it reads as informative, not loud;
// shown on every screen (the Header renders on both sync and main). The server resolves a clean
// release to `vX.Y.Z` and any other build to `dev · branch @ hash`, so a dev build is
// unmistakable. `dev` adds a marker class purely as a class hook (text already distinguishes it).
const VersionBadge = ({ version }) =>
  version && version.text
    ? html`<span class=${"badge badge-outline version-badge ml-2" + (version.dev ? " version-dev" : "")}
                     title=${version.title || ""}>${version.text}</span>`
    : null;

// New-release callout (#224). Shown only when the server reports a newer GitHub release is available
// (`dashboard.check_for_updates`). Notify-only — a link to the release notes; the one-click upgrade
// is the separate UpgradeControl (#59). Accent so it's noticeable; opens the release page in a new tab.
const UpdateBadge = ({ update }) =>
  update && update.available && update.url
    ? html`<a class="badge badge-accent version-badge ml-2" href=${update.url}
                  target="_blank" rel="noopener noreferrer"
                  title=${"A newer Pithead release is available: " + update.latest}
               >New release ${update.latest} available ↗</a>`
    : null;

const HighUsage = ({ level }) =>
  level === "high" ? html`<span class="badge badge-bad mx-1">High Usage</span>` : null;

// Theme icons (Issue #43) — minimal Lucide-style line glyphs drawn with currentColor, so they
// pick up the segment's text colour (muted → full on hover/active). Inline SVG keeps them crisp
// at any DPI and needs no extra asset or CSP allowance.
const svgIcon = (body) => html`
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor"
         stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;

const THEME_ICON = {
  light: () =>
    svgIcon(
      html`<circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />`,
    ),
  auto: () =>
    svgIcon(html`<rect x="2" y="3" width="20" height="14" rx="2" /><path d="M8 21h8M12 17v4" />`),
  dark: () => svgIcon(html`<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />`),
};

// Fixed bottom-right segmented control to pick light / auto / dark (Issue #43). Icon-only and
// visually quiet, with the active segment raised; the order/labels come from logic.mjs. Rendered
// in every app state (loading / sync / dashboard) so it's always reachable; the choice is
// persisted by the onTheme handler in dashboard.js.
const ThemeSwitcher = ({ theme, onTheme }) => {
  const current = theme || "auto";
  return html`
    <div class="theme-switcher" role="group" aria-label="Theme">
        ${THEME_ORDER.map(
          (id) => html`
            <button type="button" class=${"theme-seg" + (id === current ? " active" : "")}
                    title=${"Theme: " + THEME_LABELS[id]} aria-label=${THEME_LABELS[id]}
                    aria-pressed=${id === current} onClick=${() => onTheme(id)}>
                ${THEME_ICON[id]()}
            </button>`,
        )}
    </div>`;
};

// --- Hero KPI band -------------------------------------------------------------------

// A prominent strip of the headline numbers (total hashrate, shares in window, blocks found, XvB
// tier, mining mode) shown above the operational view (Issue #81). heroKpis (logic.mjs,
// unit-tested) does the selection/labelling/colouring; this only renders the list. Rendered only
// when operational — during sync the numbers aren't meaningful yet.
const HeroBand = ({ state }) => html`
    <div class="hero-band" id="hero-band">
        ${heroKpis(state).map(
          (k) => html`
            <div class="hero-kpi">
                <div class=${"hero-value " + (k.cls || "")}>${k.value}</div>
                <div class="hero-label">${k.label}</div>
            </div>`,
        )}
    </div>`;

export {
  Badges,
  cVar,
  HeroBand,
  HighUsage,
  netCls,
  SharesStat,
  ThemeSwitcher,
  UpdateBadge,
  VersionBadge,
};
