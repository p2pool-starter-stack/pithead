import { stackStatus } from "./status.mjs";

export const UNAVAILABLE = "Unavailable";
export const RANGES = { "24h": "Day", "1w": "Week", "1m": "Month" };
export const number = (value) => typeof value === "number" && Number.isFinite(value) && value >= 0;
export const link = (page, section, extra = {}) => {
  const query = new URLSearchParams({ page, ...extra });
  if (section) query.set("advanced", section);
  return `?${query}`;
};

export function attention(state) {
  if (!state) return [];
  const items = [];
  const add = (kind, text, page, section, extra) =>
    items.push({ kind, text, href: link(page, section, extra) });
  const workers = [...(state.workers || [])].sort(
    (a, b) =>
      String(a.name).localeCompare(String(b.name)) || String(a.ip).localeCompare(String(b.ip)),
  );
  for (const worker of workers)
    if (worker.status === "offline")
      add("rig", `${worker.name}: offline. Check its connection.`, "machines", "pool-and-rigs", {
        worker: worker.name,
      });
  for (const chain of ["monero", ...(state.overview?.tari_enabled ? ["tari"] : [])]) {
    const sync = state.sync?.[chain];
    if (sync && sync.state !== "done")
      add(
        "node",
        `${chain === "monero" ? "Monero" : "Tari"} is not synced. Check node progress.`,
        "settings",
        "node-and-network",
      );
  }
  if (["Balance", "Privacy"].includes(state.profile?.name) && state.egress?.summary?.level !== "ok")
    add(
      "tor",
      "Tor health needs checking for this profile. Review the network connection.",
      "settings",
      "node-and-network",
    );
  if (state.system?.disk?.level === "high")
    add("disk", "Disk space is low. Review this machine's storage.", "overview", "maintenance");
  if (state.update?.available)
    add(
      "update",
      "A Pithead update is available. Review the update.",
      "settings",
      "update-details",
    );
  if (state.overview?.backup_recorded === false)
    add(
      "backup",
      "No successful backup is recorded. Create a recovery backup.",
      "settings",
      "backup",
    );
  if ((state.badges || []).some((b) => /wallet changed/i.test(b.text)))
    add("tamper", "The payout wallet changed. Review the recorded change.", "settings", "payout");
  if (state.db_healthy === false || (state.overview?.config_warnings || []).length)
    add(
      "config",
      "Configuration or recording needs attention. Review the diagnostics.",
      "settings",
      "configuration-json",
    );
  if (number(state.overview?.shares_failed) && state.overview.shares_failed > 0)
    add(
      "shares",
      `${state.overview.shares_failed} P2Pool shares failed in the current process counters. Review pool health.`,
      "overview",
      "inspect",
    );
  if (state.overview?.pool_tier_suggestion)
    add(
      "pool",
      `Review the pool-tier suggestion for the measured hashrate; the tier will not change automatically.`,
      "machines",
      "pool-and-rigs",
    );
  return items;
}

export function overviewStatus(state, connected, now = Date.now()) {
  if (!connected)
    return "Disconnected. These are the last recorded readings; reconnect before relying on them.";
  if (!state) return "Waiting for the first snapshot. Check the dashboard connection.";
  const ts = state.overview?.snapshot_ts;
  if (!number(ts) || now - ts * 1000 > 120000)
    return "Snapshot freshness is unavailable or stale. Check the dashboard connection.";
  if (state.syncing)
    return "Nodes are synchronizing. Mining waits for the required nodes to be ready.";
  const problems = attention(state);
  if (problems.length)
    return `${problems.length} ${problems.length === 1 ? "item needs" : "items need"} attention. Follow the links below.`;
  if (stackStatus(state, true).level !== "ok")
    return "Health is not confirmed. Review the node and machine readings.";
  return "Everything is running normally";
}

export function combinedRate(chart = {}) {
  const xvb = new Map((chart.xvb || []).map((point) => [point.x, point.y]));
  return (chart.p2pool || []).map((point) => ({
    x: point.x,
    y: number(point.y) && number(xvb.get(point.x)) ? point.y + xvb.get(point.x) : null,
  }));
}

export function destinations(state) {
  const output = [];
  const points = state?.chart?.p2pool || [];
  const xvb = state?.chart?.xvb || [];
  const p = points.filter((point) => number(point.y)).reduce((sum, point) => sum + point.y, 0);
  const x = xvb.filter((point) => number(point.y)).reduce((sum, point) => sum + point.y, 0);
  const total = p + x;
  if (total <= 0) return output;
  const project = state.overview?.donations?.project;
  const developer = state.overview?.donations?.xmrig;
  const configured = [project, developer].filter(number).reduce((sum, value) => sum + value, 0);
  const remaining = Math.max(0, 100 - configured);
  if (p > 0)
    output.push({
      key: "p2pool",
      label: "P2Pool",
      percent: (p / total) * remaining,
      estimated: false,
    });
  if (state.overview?.xvb_enabled && x > 0)
    output.push({ key: "xvb", label: "XvB", percent: (x / total) * remaining, estimated: false });
  if (number(project) && project > 0)
    output.push({ key: "project", label: "Pithead project", percent: project, estimated: true });
  if (number(developer) && developer > 0)
    output.push({ key: "xmrig", label: "XMRig developers", percent: developer, estimated: true });
  return output;
}

export function activityEntries(state, audit, access) {
  const rows = [];
  const add = (ts, source, text) => {
    const seconds = typeof ts === "number" ? ts : Date.parse(ts) / 1000;
    if (number(seconds) && seconds > 0) rows.push({ ts: seconds, source, text });
  };
  if (Array.isArray(state?.overview_activity?.entries)) {
    for (const entry of state.overview_activity.entries) add(entry.ts, "Mining", entry.text);
  } else {
    for (const p of state?.chart?.payouts || [])
      add(p.x / 1000, "Mining", "Confirmed Monero payout");
    for (const p of state?.blocks || []) add(p.x / 1000, "Mining", "P2Pool block found");
    for (const p of state?.chart?.shares || [])
      add(p.x / 1000, "Mining", "P2Pool share recorded; a share does not promise a payout");
    for (const p of state?.chart?.raffle || [])
      add(p.x / 1000, "Mining", "XvB raffle win recorded");
    for (const p of state?.chart?.events || [])
      add(
        p.x / 1000,
        "Mining",
        p.kind === "hashrate_recovered" ? "Hashrate recovered" : "Mining status changed",
      );
  }
  for (const entry of audit?.entries || []) {
    const status = [
      "applied",
      "rejected",
      "failed",
      "rolled_back",
      "ok",
      "accepted",
      "success",
      "pending",
    ].includes(entry.status)
      ? entry.status
      : "outcome unavailable";
    add(entry.ts, "Settings", `Settings change: ${status}`);
  }
  const seenAccess = new Set();
  for (const entry of access?.entries || []) {
    if (
      entry.status < 200 ||
      entry.status >= 400 ||
      !entry.user ||
      !["/", "/ui-preview"].includes((entry.uri || "").split("?")[0])
    )
      continue;
    const key = `${entry.ts}:${entry.user}`;
    if (!seenAccess.has(key))
      add(
        entry.ts,
        "Access",
        "Authenticated dashboard visit (access record, not a session sign-in)",
      );
    seenAccess.add(key);
  }
  return rows.sort(
    (a, b) => b.ts - a.ts || a.source.localeCompare(b.source) || a.text.localeCompare(b.text),
  );
}
