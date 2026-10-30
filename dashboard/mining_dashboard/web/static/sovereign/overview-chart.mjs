import { fmtHashrate } from "../app/logic.mjs";
import { Component, html } from "../app/preact.mjs";
import { combinedRate, destinations, link, number, RANGES } from "./overview-model.mjs";

export function zoomWindow(min, max, factor = 0.5, shift = 0) {
  if (!number(min) || !number(max) || max <= min) return null;
  const span = Math.max(60000, (max - min) * factor);
  const center = (min + max) / 2 + (max - min) * shift;
  return { from: Math.max(1, center - span / 2) / 1000, to: (center + span / 2) / 1000 };
}

export class OverviewChart extends Component {
  constructor(props) {
    super(props);
    this.canvas = null;
    this.chart = null;
    this.state = { series: {} };
  }
  componentDidMount() {
    this.sync();
  }
  componentDidUpdate() {
    this.sync();
  }
  componentWillUnmount() {
    this.chart?.destroy();
    clearTimeout(this.debounce);
  }
  gesture() {
    clearTimeout(this.debounce);
    this.debounce = setTimeout(() => {
      const axis = this.chart?.scales.x;
      const window = axis && zoomWindow(axis.min, axis.max, 1);
      if (window) this.props.onWindow(window);
    }, 300);
  }
  key(event) {
    const axis = this.chart?.scales.x;
    if (!axis) return;
    const actions = {
      "+": [0.5, 0],
      "=": [0.5, 0],
      "-": [2, 0],
      ArrowLeft: [1, -0.25],
      ArrowRight: [1, 0.25],
    };
    if (event.key === "Home" || event.key === "0") {
      event.preventDefault();
      this.props.onWindow(null);
      return;
    }
    if (actions[event.key]) {
      event.preventDefault();
      this.props.onWindow(zoomWindow(axis.min, axis.max, ...actions[event.key]));
    }
  }
  strip(chart) {
    const state = this.props.state;
    const shares = destinations(state);
    if (!shares.some((part) => part.key !== "p2pool")) return;
    const area = chart.chartArea;
    const points = state?.chart?.p2pool || [];
    const other = new Map((state?.chart?.xvb || []).map((point) => [point.x, point.y]));
    const colors = this.colors();
    for (let i = 0; i < points.length - 1; i++) {
      const point = points[i],
        next = points[i + 1];
      if (!number(point.y) || !number(next.y) || !number(other.get(point.x))) continue;
      const lo = Math.max(area.left, chart.scales.x.getPixelForValue(point.x));
      const hi = Math.min(area.right, chart.scales.x.getPixelForValue(next.x));
      const total = point.y + other.get(point.x);
      if (hi <= lo || total <= 0) continue;
      const fixed = shares
        .filter((part) => part.estimated)
        .reduce((sum, part) => sum + part.percent, 0);
      let top = area.bottom + 25;
      for (const part of shares) {
        const percent = part.estimated
          ? part.percent
          : ((part.key === "p2pool" ? point.y : other.get(point.x)) / total) * (100 - fixed);
        const height = (percent / 100) * 16;
        chart.ctx.fillStyle = colors[part.key];
        chart.ctx.fillRect(lo, top, hi - lo, height);
        top += height;
      }
    }
  }
  colors() {
    const style = getComputedStyle(document.documentElement);
    const read = (name) => style.getPropertyValue(name).trim();
    return {
      p2pool: read("--accent"),
      xvb: read("--ok"),
      project: read("--warn"),
      xmrig: read("--bad"),
      text: read("--muted"),
      border: read("--border"),
    };
  }
  sync() {
    if (!this.canvas || typeof Chart === "undefined") return;
    const state = this.props.state;
    const chart = state?.chart || {};
    const colors = this.colors();
    const datasets = [
      {
        label: "Hashrate",
        data: combinedRate(chart),
        borderColor: colors.p2pool,
        pointRadius: 0,
        borderWidth: 2,
        spanGaps: false,
      },
      {
        type: "scatter",
        label: "Confirmed payouts",
        data: chart.payouts || [],
        yAxisID: "markers",
        backgroundColor: colors.xvb,
        pointRadius: 5,
      },
    ];
    if (this.props.advanced)
      for (const [key, label] of [
        ["shares", "Shares"],
        ["events", "Mining events"],
        ["raffle", "Raffle wins"],
      ]) {
        if (this.state.series[key])
          datasets.push({
            type: "scatter",
            label,
            data: chart[key] || [],
            yAxisID: "markers",
            backgroundColor: colors.project,
            pointRadius: 4,
          });
      }
    if (this.props.advanced && this.state.series.xvb)
      datasets.push({
        label: "XvB %",
        data: (state?.xvb_history || []).map((p) => ({ x: p.x, y: p.donation_fraction * 100 })),
        yAxisID: "percent",
        borderColor: colors.xmrig,
        pointRadius: 0,
      });
    const limits = this.props.window
      ? { min: this.props.window.from * 1000, max: this.props.window.to * 1000 }
      : {};
    const options = {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      parsing: false,
      layout: { padding: { bottom: 45 } },
      plugins: {
        legend: { display: false },
        zoom: {
          limits: { x: { minRange: 60000 } },
          pan: {
            enabled: true,
            mode: "x",
            modifierKey: "shift",
            onPanComplete: () => this.gesture(),
          },
          zoom: {
            mode: "x",
            wheel: { enabled: true, modifierKey: "ctrl" },
            pinch: { enabled: true },
            drag: { enabled: true, backgroundColor: `${colors.p2pool}33` },
            onZoomComplete: () => this.gesture(),
          },
        },
      },
      scales: {
        x: {
          type: "linear",
          ...limits,
          grid: { color: colors.border },
          ticks: {
            color: colors.text,
            maxTicksLimit: 5,
            callback: (value) =>
              new Date(value).toLocaleString([], {
                month: "short",
                day: "numeric",
                hour: "2-digit",
                minute: "2-digit",
              }),
          },
        },
        y: {
          beginAtZero: true,
          grid: { color: colors.border },
          ticks: { color: colors.text, callback: fmtHashrate },
        },
        markers: { display: false, min: 0, max: 1 },
        percent: { display: false, min: 0, max: 100 },
      },
    };
    if (!this.chart) {
      if (globalThis.ChartZoom) Chart.register(globalThis.ChartZoom);
      this.chart = new Chart(this.canvas, {
        type: "line",
        data: { datasets },
        options,
        plugins: [{ id: "destinationStrip", afterDraw: (instance) => this.strip(instance) }],
      });
    } else {
      this.chart.data.datasets = datasets;
      this.chart.options = options;
      this.chart.update("none");
    }
  }
  render({ state, range, onRange, advanced }) {
    const parts = destinations(state);
    const hasStrip = parts.some((part) => part.key !== "p2pool");
    const points = combinedRate(state?.chart);
    return html`<section class="panel overview-chart" aria-label="Hashrate history">
      <div class="overview-row"><h2>Hashrate</h2><label>Chart range <select aria-label="Chart range" value=${range} onChange=${(event) => onRange(event.target.value)}>
        ${Object.entries(RANGES).map(([value, label]) => html`<option value=${value}>${label}</option>`)}
      </select></label></div>
      <p id=${advanced ? "advanced-chart-keys" : "chart-keys"} class="muted">Drag or pinch to zoom. Shift-drag or arrow keys to pan. + and − zoom; Home or double tap resets. Ordinary scrolling scrolls the page.</p>
      ${points.filter((p) => number(p.y)).length < 2 ? html`<p>Insufficient hashrate history. Wait for more samples.</p>` : null}
      <div class="overview-canvas"><canvas tabindex="0" role="img" aria-label="Hashrate over real time with confirmed payout markers" aria-describedby=${advanced ? "advanced-chart-keys" : "chart-keys"}
        ref=${(node) => {
          this.canvas = node;
        }} onKeyDown=${(event) => this.key(event)}
        onDblClick=${() => this.props.onWindow(null)} onTouchEnd=${() => {
          const now = Date.now();
          if (now - this.lastTap < 300) this.props.onWindow(null);
          this.lastTap = now;
        }}>Hashrate history is available through the readings and activity below.</canvas></div>
      ${hasStrip ? html`<ul class="destination-legend" aria-label="Where the hashrate went">${parts.map((part) => html`<li><span class=${`destination-dot destination-${part.key}`}></span>${part.label}: ${part.percent.toFixed(1)}%${part.estimated ? " (configured share, estimated timing)" : " (sampled routed share)"}</li>`)}</ul>` : null}
      <p class="muted">Project and XMRig donation readings: ${state?.overview?.donations ? "reported configured shares; exact timing is not observable" : "unavailable until the donation producers report them"}.</p>
      ${(state?.chart?.payouts || []).map((p) => html`<a class="payout-marker-link" href=${link("overview", "activity")}>Confirmed payout · ${new Date(p.x).toLocaleString()}</a>`)}
      ${
        advanced
          ? html`<fieldset><legend>Extra chart series</legend>${[
              ["shares", "Shares"],
              ["events", "Mining events"],
              ["raffle", "Raffle wins"],
              ["xvb", "XvB %"],
            ].map(
              ([key, label]) =>
                html`<label><input type="checkbox" checked=${!!this.state.series[key]} onChange=${(event) => this.setState({ series: { ...this.state.series, [key]: event.target.checked } })} /> ${label}</label>`,
            )}</fieldset>`
          : null
      }
    </section>`;
  }
}
