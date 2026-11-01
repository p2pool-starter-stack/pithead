export const RIG_WORDS = {
  pending: "Waiting",
  running: "Upgrading…",
  applied: "Upgraded",
  noop: "Already current",
  throttled: "Retry later",
  accepted: "Requested, not confirmed done",
  rolled_back: "Rolled back",
  rejected: "Rejected",
  failed: "Failed",
  not_started: "Not started",
};

const SETTLED = new Set([
  "applied",
  "noop",
  "throttled",
  "accepted",
  "rolled_back",
  "rejected",
  "failed",
  "not_started",
]);
const RECENT_S = 86400;

export function fleetControl({ controlEnabled, writable, plan, run }) {
  const eligible = Array.isArray(plan?.eligible) ? plan.eligible : [];
  return (
    controlEnabled === true &&
    writable === true &&
    !!plan?.version &&
    eligible.length > 0 &&
    !runActive(run)
  );
}

export function runActive(run) {
  return run?.status === "running";
}

export function runView(run, now = Date.now() / 1000) {
  if (!run || (!runActive(run) && now - (Number(run.ts) || 0) > RECENT_S)) return null;
  const rigs = (Array.isArray(run.rigs) ? run.rigs : []).map((rig) => ({
    name: String(rig?.name ?? ""),
    status: rig?.status ?? "pending",
    word: RIG_WORDS[rig?.status] ?? String(rig?.status ?? "Waiting"),
    reason: rig?.reason || null,
    settled: SETTLED.has(rig?.status),
  }));
  const settled = rigs.filter((rig) => rig.settled).length;
  const headline = runActive(run)
    ? `Updating to ${run.version}: ${settled} of ${rigs.length} rigs settled.`
    : run.status === "rejected"
      ? `The update was rejected: ${run.error || "no reason given"}`
      : `Update to ${run.version} finished: ${settled} of ${rigs.length} rigs settled.`;
  return { headline, rigs, active: runActive(run) };
}
