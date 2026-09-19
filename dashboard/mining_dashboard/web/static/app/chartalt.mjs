// Text alternative for the hashrate canvases (WCAG 1.1.1, #1859): a bare <canvas> exposes nothing
// to a screen reader, so each carries role="img" plus a label naming what it currently shows.
// Split out of chart.mjs, which sits at its file-budget ceiling.
import { fmtHashrate } from "./logic.mjs";

function latestPoint(series) {
  for (let i = (series || []).length - 1; i >= 0; i--) {
    if (series[i].y != null) return series[i].y;
  }
  return 0;
}

export function chartAriaLabel(chart, avgWindow, windows) {
  const total = latestPoint(chart?.p2pool) + latestPoint(chart?.xvb);
  const windowLabel = (windows.find(([w]) => w === avgWindow) || [])[1] || avgWindow;
  return `Hashrate chart: ${fmtHashrate(total)} total, ${windowLabel} average`;
}

export function workerChartAriaLabel(hashrateSeries) {
  return `Hashrate chart: ${fmtHashrate(latestPoint(hashrateSeries))}`;
}
