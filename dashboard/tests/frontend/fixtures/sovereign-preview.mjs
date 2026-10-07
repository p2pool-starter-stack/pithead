#!/usr/bin/env node
import { createReadStream, readFileSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BROWSER_CHECKS,
  CHECKS_HTML,
  WIZARD_VARIANTS,
  wizardPreviewHtml,
  wizardPreviewState,
} from "./wizard-preview.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = resolve(HERE, "../../../mining_dashboard/web");
const STATIC = join(WEB, "static");
const INDEX = join(WEB, "templates/index.html");
const BASE = JSON.parse(readFileSync(join(HERE, "state.json"), "utf8"));
const CSP =
  "default-src 'self'; img-src 'self' data:; style-src 'self'; " +
  "script-src 'self'; connect-src 'self'; frame-ancestors 'none'; " +
  "base-uri 'self'; form-action 'self'";
const TYPES = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
};
const SERIES_END = 1_735_776_000_000;
const TEN_MINUTES = 10 * 60 * 1000;

function chartSeries() {
  return Array.from({ length: 145 }, (_, index) => {
    const y =
      index < 18
        ? 12_400 + index * 700
        : Math.round(24_800 + 480 * Math.sin(index / 9) + 160 * Math.sin(index / 3));
    return { x: SERIES_END - (144 - index) * TEN_MINUTES, y: index === 144 ? 24_800 : y };
  });
}

const worker = (name, ip, status, h60, accepted, rejected) => ({
  ...structuredClone(BASE.workers[0]),
  name,
  ip,
  status,
  h60,
  h15: h60,
  h15_str: `${(h60 / 1000).toFixed(2)} kH/s`,
  h60_str: h60 ? `${(h60 / 1000).toFixed(2)} kH/s` : "0.00 H/s",
  uptime: status === "online" ? 24120 : 0,
  uptime_str: status === "online" ? "6h 42m" : "—",
  rigforge: null,
  accepted,
  accepted_str: accepted.toLocaleString("en-US"),
  rejected,
  rejected_str: rejected.toLocaleString("en-US"),
});

export function previewState(variant = "sample") {
  const state = structuredClone(BASE);
  state.version = {
    dev: true,
    text: "Sample data · local preview",
    title: "Synthetic local preview data",
  };
  state.page_title = "Pithead · Sovereign sample";
  state.last_update = "12:34:56";
  state.control_enabled = false;
  state.host_addr = "preview-host.local";
  state.host_ip = "192.0.2.10";
  state.hashrate = {
    ...state.hashrate,
    total: "24.80 kH/s",
    p2p_1h: "24.92 kH/s",
    p2p_24h: "24.80 kH/s",
    target_tier: "Off",
    tier: "Off",
    xvb_1h: "0.00 H/s",
    xvb_24h: "0.00 H/s",
    xvb_routed_1h: "0.00 H/s",
    xvb_routed_24h: "0.00 H/s",
  };
  state.proxy_workers = 2;
  state.proxy_summary = {
    ...state.proxy_summary,
    accepted: "18,440",
    has_data: true,
    rejected: "12",
    reject_pct: "0.07%",
  };
  state.stratum = {
    ...state.stratum,
    conns: 2,
    h1h: "24.92 kH/s",
    h24h: "24.80 kH/s",
    last_share: "42 seconds ago",
    shares: "18,440 / 12",
  };
  state.chart = {
    ...state.chart,
    events: [
      {
        label: "garage-spare stopped reporting",
        x: SERIES_END - 70 * TEN_MINUTES,
      },
    ],
    p2pool: chartSeries(),
    payouts: [
      { label: "0.000340 XMR — sample payout", x: SERIES_END - 18 * TEN_MINUTES, y: 0.58 },
    ],
    raffle: [],
    shares: Array.from({ length: 7 }, (_, index) => ({
      c: 1,
      r: 9,
      x: SERIES_END - index * 20 * TEN_MINUTES,
      y: 0.93,
    })),
    xvb: [],
  };
  state.earnings = {
    ...state.earnings,
    available: true,
    block_reward: "0.6000 XMR",
    coeff_day: 1.37e-8,
    confirmed: {
      enabled: true,
      count: 18,
      last_ts: SERIES_END / 1000 - 3_600,
      since_ts: SERIES_END / 1000 - 45 * 86_400,
      partial: { yesterday: false, "7d": false, "30d": false },
      xmr_24h: 0.00034,
      xmr_yesterday: 0.00031,
      xmr_7d: 0.00225,
      xmr_30d: 0.0096,
      xmr_all: 0.0412,
      n_30d: 18,
    },
    p2pool_hr: 24_800,
    p2pool_hr_str: "24.80 kH/s",
    pool_difficulty: 260_000_000,
    xvb_day: null,
  };
  state.earnings_summary = {
    ...state.earnings_summary,
    xmr: {
      actual_30d: 0.0096,
      available: true,
      enabled: true,
      expected_30d: 0.0101928,
      includes_xvb: false,
      partial: false,
      pct: 94,
      xvb_realization_pct: null,
      xvb_wins_measured: null,
    },
    xvb: { enabled: false, expected_wins_30d: null, last_win_ts: null, wins_30d: 0 },
  };
  state.xvb_calc = {
    ...state.xvb_calc,
    current_tier: "None",
    enabled: false,
    estimates_available: false,
    target_threshold: null,
    target_tier: null,
    tiers: [],
  };
  state.xvb_history = [];
  state.raffle_wins = [];
  state.raffle_eligible = { applies: false, eligible: false, label: "N/A" };
  state.update = { available: false, latest: null, url: null };
  state.network = {
    ...state.network,
    diff: "438.20 G",
    hash: "3.67 GH/s",
    height: 3_312_640,
    reward: "0.6000 XMR",
    ts: "12:33:41",
  };
  state.monero = { ...state.monero, db_size: "146.2 GB" };
  state.pool = {
    ...state.pool,
    blocks: 14,
    diff: "260.00 M",
    hr: "18.72 MH/s",
    last_blk: "2h 18m ago",
    miners: 384,
    peers: "9 / 12",
    sidechain_height: 6_482_193,
    uptime: "12d 4h",
  };
  state.system = {
    ...state.system,
    cpu: { level: "ok", load: "1m: 1.84 5m: 1.72 15m: 1.60", percent: "36.4%" },
    disk: {
      fill: "",
      level: "ok",
      percent: "23%",
      total: "930.0",
      unit: "GB",
      used: "214.0",
      width: "23%",
    },
    hugepages: { status: "Enabled", value: "1280/1280", variant: "ok" },
    mem: { level: "ok", percent: "40%", total: "15.5", used: "6.2" },
  };
  state.energy = {
    ...state.energy,
    hs_per_watt: 47.51,
    per_worker: [
      { estimated: false, hs: 12_600, hs_per_watt: 47.37, name: "workbench-01", watts: 266 },
      { estimated: false, hs: 12_200, hs_per_watt: 47.66, name: "rack-node-02", watts: 256 },
    ],
    total_watts: 522,
  };
  state.shares_window = { count: 7, ok: true };
  state.workers = [
    worker("workbench-01", "192.0.2.21", "online", 12_600, 8_940, 3),
    worker("rack-node-02", "192.0.2.22", "online", 12_200, 9_500, 9),
    worker("garage-spare", "192.0.2.23", "offline", 0, 0, 0),
  ];

  if (variant === "empty") {
    state.hashrate.total = "0.00 H/s";
    state.hashrate.p2p_1h = "0.00 H/s";
    state.hashrate.p2p_24h = "0.00 H/s";
    state.proxy_workers = 0;
    state.workers = [];
  } else if (variant === "sync") {
    state.syncing = true;
    state.sync.monero = {
      ...state.sync.monero,
      current: 2_880_000,
      percent: 96,
      remaining: 120_000,
      state: "syncing",
      target: 3_000_000,
    };
  }
  return state;
}

function headers(type) {
  return {
    "Cache-Control": "no-cache",
    "Content-Security-Policy": CSP,
    "Content-Type": type,
    // Same-origin API polls use the page's fixture selector; external links receive no Referer.
    "Referrer-Policy": "same-origin",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
  };
}

function json(res, status, body, head = false) {
  res.writeHead(status, headers("application/json; charset=utf-8"));
  res.end(head ? undefined : `${JSON.stringify(body)}\n`);
}

function text(res, type, body, head = false) {
  res.writeHead(200, headers(type));
  res.end(head ? undefined : body);
}

function file(res, path, head) {
  try {
    if (!statSync(path).isFile()) throw new Error("not a file");
  } catch {
    return json(res, 404, { error: "Not found" }, head);
  }
  res.writeHead(200, headers(TYPES[extname(path)] || "application/octet-stream"));
  if (head) res.end();
  else createReadStream(path).on("error", () => res.destroy()).pipe(res);
}

function fixtureVariant(req, url, allowed = ["empty", "sync"], fallback = "sample") {
  let variant = url.searchParams.get("fixture");
  if (!variant && req.headers.referer) {
    try {
      const referer = new URL(req.headers.referer);
      if (referer.host === req.headers.host) variant = referer.searchParams.get("fixture");
    } catch {
      // A malformed or cross-origin Referer cannot select preview data.
    }
  }
  return allowed.includes(variant) ? variant : fallback;
}

export function createPreviewServer() {
  return createServer((req, res) => {
    if (!req.url) return json(res, 400, { error: "Malformed request" });
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.setHeader("Allow", "GET, HEAD");
      return json(res, 405, { error: "Local preview is read-only" });
    }
    const head = req.method === "HEAD";
    let url;
    let pathname;
    try {
      url = new URL(req.url, "http://127.0.0.1");
      pathname = decodeURIComponent(url.pathname);
    } catch {
      return json(res, 400, { error: "Malformed URI" }, head);
    }
    if (pathname === "/") return file(res, INDEX, head);
    if (pathname === "/wizard") {
      return text(res, "text/html; charset=utf-8", wizardPreviewHtml(), head);
    }
    if (pathname === "/checks") {
      return text(res, "text/html; charset=utf-8", CHECKS_HTML, head);
    }
    if (pathname === "/checks/browser-checks.mjs") return file(res, BROWSER_CHECKS, head);
    if (pathname === "/api/state") {
      return json(res, 200, previewState(fixtureVariant(req, url)), head);
    }
    if (pathname === "/api/wizard-state") {
      const variant = fixtureVariant(req, url, WIZARD_VARIANTS, "setup");
      return variant === "gate"
        ? json(res, 401, { error: "unauthenticated" }, head)
        : json(res, 200, wizardPreviewState(variant), head);
    }
    if (pathname === "/api/audit") return json(res, 200, { entries: [] }, head);
    if (pathname === "/api/access") {
      return json(res, 200, { available: false, entries: [], failures_24h: 0 }, head);
    }
    if (pathname.startsWith("/api/")) return json(res, 404, { error: "Unavailable in preview" }, head);
    if (!pathname.startsWith("/static/")) return json(res, 404, { error: "Not found" }, head);

    const path = resolve(STATIC, pathname.slice("/static/".length));
    if (path !== STATIC && !path.startsWith(`${STATIC}${sep}`)) {
      return json(res, 403, { error: "Forbidden path" }, head);
    }
    file(res, path, head);
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || "8765");
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error("PORT must be an integer from 1 to 65535");
    process.exitCode = 1;
  } else {
    createPreviewServer().listen(port, "127.0.0.1", () => {
      console.log(`Sovereign preview: http://127.0.0.1:${port}/?ui=sovereign`);
      console.log("Synthetic sample data only; server is read-only.");
    });
  }
}
