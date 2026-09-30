// The chart card's Range/Avg control rows (#1874): a labelled button row for desktop/tablet, plus
// a native <select> fallback for phone widths, swapped in by a CSS media query (styles/chart.css)
// rather than script — the select's accessible name is the row's own visible label ("Range"/
// "Avg"), via aria-label. Split out of chart.mjs to stay under its file-budget ceiling.
import { html } from "./preact.mjs";

export function controlSelect(ariaLabel, options, isSelected, onChange) {
  return html`<select class="chart-controls-select" aria-label=${ariaLabel}
      onChange=${(e) => onChange(e.target.value)}>
      ${options.map(([v, label]) => html`<option value=${v} selected=${isSelected(v)}>${label}</option>`)}
  </select>`;
}

export function rangeControls(RANGES, zoomed, props) {
  return html`${RANGES.map(
    // Real buttons (#657); the ?range= deep link survives via history.replaceState.
    ([r, label]) => html`<button type="button"
        class=${"btn-range" + (!zoomed && props.range === r ? " active" : "")}
        aria-pressed=${!zoomed && props.range === r}
        title=${"Chart range: " + label}
        onClick=${() => props.onRange(r)}>${label}</button>`,
  )}
    ${controlSelect("Range", RANGES, (r) => !zoomed && props.range === r, props.onRange)}
    ${
      zoomed
        ? html`<button class="btn-range btn-reset" onClick=${() => props.onResetZoom()}>↺ Reset zoom</button>`
        : html`<span class="text-muted text-xs ml-2 chart-drag-hint">Drag to zoom · Shift-drag to pan · Ctrl-scroll to zoom</span>`
    }`;
}

export function avgControls(WINDOWS, WINDOW_HINT, props) {
  const onAvg = (w) => props.onAvgWindow?.(w);
  return html`${WINDOWS.map(
    ([w, label]) => html`<button type="button"
        class=${"btn-range" + (props.avgWindow === w ? " active" : "")}
        aria-pressed=${props.avgWindow === w}
        title=${WINDOW_HINT[w] || label + " average"}
        onClick=${() => onAvg(w)}>${label}</button>`,
  )}
    ${controlSelect("Avg", WINDOWS, (w) => props.avgWindow === w, onAvg)}`;
}
