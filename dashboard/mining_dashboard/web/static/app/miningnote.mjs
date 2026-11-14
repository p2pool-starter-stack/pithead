export function aliveHere(worker) {
  return (
    worker.status === "online" && !["on_backup", "not_connected"].includes(worker.mining?.state)
  );
}

export function miningNote(worker) {
  const { state, pool } = worker.mining || {};
  if (state === "on_backup") return "on backup pool: " + pool;
  if (state === "not_connected") return "not connected to this Pithead";
  if (state === "unknown") return "mining location unknown";
  if (aliveHere(worker)) return null;
  if (worker.telemetry_h60 > 0) return "telemetry only — not this Pithead";
  return worker.h60 > 0 || worker.h15 > 0 ? "no live connection here" : null;
}
