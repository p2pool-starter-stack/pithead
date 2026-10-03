import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "../../../..");
const TEMPLATE = readFileSync(
  join(ROOT, "dashboard/mining_dashboard/web/templates/wizard.html"),
  "utf8",
);
const reference = JSON.parse(readFileSync(join(ROOT, "config.reference.json"), "utf8"));
delete reference._docs;

export const WIZARD_VARIANTS = [
  "gate",
  "setup",
  "reinstall",
  "rig",
  "credentials",
  "installing",
  "failed",
];

const disks = [
  {
    name: "preview-empty",
    size: "931.5G",
    model: "Sample empty SSD",
    serial: "SAMPLE-EMPTY",
    state: "empty",
  },
  {
    name: "preview-data",
    size: "3.6T",
    model: "Sample existing Pithead disk",
    serial: "SAMPLE-DATA",
    state: "pithead-with-data",
  },
];

export function wizardPreviewState(variant = "setup") {
  const state = {
    stage: "installer",
    mode: "installer",
    config: structuredClone(reference),
    reference: structuredClone(reference),
    error: null,
    disks: structuredClone(disks),
    rig_defaults: {
      pool: "stratum+tcp://sample-pithead.invalid:3333",
      worker: "sample-rig",
    },
    data_wiped: {},
    handoff: null,
    saved_role: null,
    node_probe: null,
    config_changes: [],
    install_attempt: {},
    auth_mode: "auto",
    restore_enabled: true,
  };

  if (variant === "reinstall") {
    state.saved_role = { role: "both" };
  } else if (variant === "rig") {
    state.saved_role = {
      role: "rig",
      pool: "stratum+tcp://sample-pithead.invalid:3333",
      worker: "sample-rig",
    };
  } else if (variant === "credentials") {
    // Presentation only: the production client derives installer state from the server stage,
    // and this preview server refuses the acknowledgement POST that would release an install.
    state.stage = "handoff";
    state.handoff = {
      username: "sample-admin",
      password: "SAMPLE-ONLY-NOT-A-REAL-PASSWORD",
      dashboard: "https://sample-device.invalid",
      stratum: "stratum+tcp://sample-device.invalid:3333",
    };
  } else if (variant === "installing") {
    state.stage = "installing";
  } else if (variant === "failed") {
    state.stage = "failed";
    state.error = "Sample failure: target disk became unavailable.";
    state.install_attempt = { disk: "preview-empty", wipe: "all" };
    state.config_changes = ["sample configuration retained for review"];
  }
  return state;
}

export function wizardPreviewHtml() {
  const links = WIZARD_VARIANTS.map(
    (variant) => `<a href="/wizard?ui=sovereign&amp;fixture=${variant}">${variant}</a>`,
  ).join(" · ");
  const nav = `<div class="sov-preview-bar"><strong>Sample device · Read-only preview</strong><nav aria-label="Preview stage">${links}</nav></div>`;
  return TEMPLATE.replace("<main id=\"app\"", `${nav}\n    <main id=\"app\"`);
}

export const CHECKS_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Sovereign browser checks</title>
<script src="/static/theme-init.js"></script>
<link rel="stylesheet" href="/static/dashboard.css">
<script src="/static/vendor/chart.umd.min.js"></script>
<script src="/static/vendor/hammer.min.js"></script>
<script src="/static/vendor/chartjs-plugin-zoom.min.js"></script></head>
<body><div id="app"></div><pre id="results">Running…</pre>
<script type="module" src="/checks/browser-checks.mjs"></script></body></html>`;

export const BROWSER_CHECKS = join(
  ROOT,
  "dashboard/tests/frontend/sovereign/browser-checks.mjs",
);
