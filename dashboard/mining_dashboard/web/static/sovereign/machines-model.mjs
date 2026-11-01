import { fmtHashrate } from "../app/logic.mjs";

export const SORTS = {
  attention: "Attention first",
  name: "Name",
  hashrate: "Hashrate",
};

export function rigView(worker) {
  const online = worker?.status === "online";
  const hashrate = Number(worker?.h60);
  const reporting = online && Number.isFinite(hashrate) && hashrate > 0;
  const behind = worker?.rigforge_update?.available === true;
  const status = !online ? "Offline" : behind ? "Behind" : "Mining";
  const note = online
    ? [!reporting && "Hashrate unavailable", worker.adopted !== true && "unmanaged"]
        .filter(Boolean)
        .join(" · ") || null
    : null;
  return {
    name: String(worker?.name ?? ""),
    status,
    note,
    attention: !online || behind || !reporting,
    reporting,
    hashrate: reporting ? fmtHashrate(hashrate) : online ? "Unavailable" : "Offline",
    rate: reporting ? hashrate : -1,
    version: worker?.rigforge?.version || null,
    latest: worker?.rigforge_update?.latest || null,
    accepted: worker?.accepted_str ?? null,
    rejected: worker?.rejected_str ?? null,
  };
}

export function rigRows(workers, { find = "", sort = "attention" } = {}) {
  const query = find.trim().toLowerCase();
  const seen = new Map();
  const rows = (Array.isArray(workers) ? workers : [])
    .map((worker, index) => {
      const row = rigView(worker);
      const occurrence = seen.get(row.name) || 0;
      seen.set(row.name, occurrence + 1);
      return { ...row, index, occurrence, key: `${occurrence}:${row.name}` };
    })
    .filter((row) => !query || row.name.toLowerCase().includes(query));
  const byName = (a, b) => a.name.localeCompare(b.name) || a.index - b.index;
  const order = {
    attention: (a, b) => b.attention - a.attention || byName(a, b),
    name: byName,
    hashrate: (a, b) => b.rate - a.rate || byName(a, b),
  };
  return rows.sort(order[sort] || order.attention);
}

export function rigSummary(workers) {
  const rows = rigRows(workers);
  const mining = rows.filter((row) => row.reporting).length;
  return `${mining} of ${rows.length} mining`;
}

export function findRig(workers, name, occurrence) {
  return (Array.isArray(workers) ? workers : []).filter((worker) => worker?.name === name)[
    occurrence
  ];
}

export function rigSettings(connection) {
  if (!connection?.url) return null;
  return connection.password_set && connection.password
    ? `Pool: ${connection.url}\nPassword: ${connection.password}`
    : `Pool: ${connection.url}`;
}

export function rigHealth(detail) {
  const points = (detail?.hashrate_history?.hashrate || []).filter(
    (point) => Number.isFinite(point?.x) && Number.isFinite(point?.y),
  );
  return {
    average: points.length
      ? fmtHashrate(points.reduce((sum, point) => sum + point.y, 0) / points.length)
      : null,
    lastSeen: points.some((point) => point.y > 0)
      ? Math.max(...points.filter((point) => point.y > 0).map((point) => point.x))
      : null,
  };
}

export function localMinerAvailable(state) {
  return state?.control_enabled === true && !!state?.os_update;
}
