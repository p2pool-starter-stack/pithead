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
  return !aliveHere(worker) && worker.telemetry_h60 > 0
    ? "telemetry only — not this Pithead"
    : null;
}
