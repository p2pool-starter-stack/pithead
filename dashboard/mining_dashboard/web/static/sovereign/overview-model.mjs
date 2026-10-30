import { fmtHashrate } from "../app/logic.mjs";
import { stackStatus } from "./status.mjs";

export const UNAVAILABLE = "Unavailable";
export const RANGES = { "24h": "Day", "1w": "Week", "1m": "Month" };
export const number = (value) => typeof value === "number" && Number.isFinite(value) && value >= 0;
export const link = (page, section, extra = {}) => {
  const query = new URLSearchParams({ page, ...extra });
  if (section) query.set("advanced", section);
  return `?${query}`;
};

export function poolAdvice(state) {
  if (!state || !Object.hasOwn(state, "pool_tier_suggestion"))
    return { available: false, suggestion: null };
  const suggestion = state.pool_tier_suggestion;
  if (suggestion === null) return { available: true, suggestion: null };
  if (
    !suggestion ||
    !["nano", "mini", "main"].includes(suggestion.tier) ||
    !number(suggestion.hashrate_24h) ||
    typeof suggestion.provisional !== "boolean"
  )
    return { available: false, suggestion: null };
  return { available: true, suggestion };
}

export function backupEvidence(state, now = Date.now()) {
  const evidence = state?.backup_status;
  return evidence?.state === "success" &&
    number(evidence.last_success_at) &&
    evidence.last_success_at > 0 &&
    evidence.last_success_at * 1000 <= now
    ? evidence
    : { state: "unknown", last_success_at: null };
}

export function snapshotFresh(state, connected, now = Date.now()) {
  const timestamp = state?.overview?.snapshot_ts;
  const age = now - timestamp * 1000;
  return connected && number(timestamp) && age >= 0 && age <= 120000;
}

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
  if (
    ["Balance", "Privacy"].includes(state.profile?.name) &&
    state.overview?.tor_health === "unhealthy"
  )
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
  if (backupEvidence(state).state === "unknown")
    add(
      "backup",
      "Backup history is unavailable. Review or create a recovery backup.",
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
  const suggestion = poolAdvice(state).suggestion;
  if (suggestion)
    add(
      "pool",
      `${suggestion.provisional ? "Provisional suggestion" : "Suggestion"}: review ${suggestion.tier} for the measured 24-hour hashrate (${fmtHashrate(suggestion.hashrate_24h)}); the tier will not change automatically.`,
      "machines",
      "pool-and-rigs",
    );
  return items;
}

export function overviewStatus(state, connected, now = Date.now()) {
  if (!connected)
    return "Disconnected. These are the last recorded readings; reconnect before relying on them.";
  if (!state) return "Waiting for the first snapshot. Check the dashboard connection.";
  if (!snapshotFresh(state, connected, now))
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

export function donationReadings(state) {
  const project = state?.donation;
  const projectPercent =
    project?.available === true
      ? project.enabled === false
        ? 0
        : project.status === "reduced"
          ? project.reduced_percent
          : project.percent
      : null;
  const developer = state?.xmrig_donation;
  const valid = (value) => number(value) && value <= 100;
  return {
    project: valid(projectPercent) ? projectPercent : null,
    xmrig: developer?.available === true && valid(developer.percent) ? developer.percent : null,
  };
}

export function destinations(state) {
  const output = [];
  const points = state?.chart?.p2pool || [];
  const xvb = new Map((state?.chart?.xvb || []).map((point) => [point.x, point.y]));
  let p = 0,
    x = 0;
  for (let index = 0; index < points.length - 1; index++) {
    const point = points[index],
      next = points[index + 1];
    if (![point.y, next.y, xvb.get(point.x), xvb.get(next.x)].every(number)) continue;
    const duration = next.x - point.x;
    if (!number(duration) || duration <= 0) continue;
    p += ((point.y + next.y) / 2) * duration;
    if (state.overview?.xvb_enabled) x += ((xvb.get(point.x) + xvb.get(next.x)) / 2) * duration;
  }
  const total = p + x;
  if (total <= 0) return output;
  const { project, xmrig } = donationReadings(state);
  const configured = [project, xmrig].filter(number).reduce((sum, value) => sum + value, 0);
  if (configured > 100) return output;
  const remaining = 100 - configured;
  if (p > 0)
    output.push({
      key: "p2pool",
      label: "P2Pool",
      percent: (p / total) * remaining,
      estimated: false,
    });
  if (x > 0)
    output.push({ key: "xvb", label: "XvB", percent: (x / total) * remaining, estimated: false });
  if (project > 0)
    output.push({ key: "project", label: "Pithead project", percent: project, estimated: true });
  if (xmrig > 0)
    output.push({ key: "xmrig", label: "XMRig developers", percent: xmrig, estimated: true });
  return output;
}

export function activityEntries(state, audit, access) {
  const rows = [];
  const add = (ts, source, text) => {
    const seconds = typeof ts === "number" ? ts : Date.parse(ts) / 1000;
    if (number(seconds) && seconds > 0 && Number.isFinite(new Date(seconds * 1000).getTime()))
      rows.push({ ts: seconds, source, text });
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
