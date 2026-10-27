const PROFILE_TEXT = {
  Performance: "Tor is off",
  Balance: "Everything goes through Tor",
  Privacy: "Tor only, rigs locked",
};

export function profileBadge(profile) {
  if (!profile || !Object.hasOwn(PROFILE_TEXT, profile.name)) return "Profile not reported";
  return `${profile.name}${profile.customized ? " (customized)" : ""}: ${PROFILE_TEXT[profile.name]}`;
}

export function stackStatus(state, connected) {
  if (!connected) return { text: "Disconnected", level: "warn" };
  if (!state) return { text: "Waiting for the first snapshot", level: "unknown" };
  const health = state.monero?.health?.level;
  const problems = new Set();
  for (const { text, variant } of state.badges || []) {
    if (!["bad", "warn"].includes(variant)) continue;
    const label = typeof text === "string" ? text.replace(/^⚠️?\s*/u, "") : "Unidentified warning";
    if (
      variant === "warn" &&
      (["Syncing...", "Miner held (sync)"].includes(label) ||
        /^Tari syncing(?: \d+(?:\.\d+)?%)?$/.test(label))
    )
      continue;
    problems.add(label === "monerod DOWN" ? "Monero chain unhealthy" : label);
  }
  if (state.db_healthy === false) problems.add("DB write failing");
  if (health === "red") problems.add("Monero chain unhealthy");
  if (problems.size) return { text: `Needs attention ${problems.size}`, level: "bad" };
  if (state.syncing) {
    const pending = Object.values(state.sync || {}).filter((chain) => chain?.state !== "done");
    const percent =
      pending.length &&
      pending.every((chain) => chain?.state !== "loading" && Number.isFinite(chain?.percent))
        ? Math.min(...pending.map((chain) => chain.percent))
        : null;
    return {
      text: Number.isFinite(percent) ? `Syncing ${percent}%` : "Syncing — progress unknown",
      level: "warn",
    };
  }
  if (health !== "green") return { text: "Health unknown", level: "unknown" };
  return { text: "Healthy", level: "ok" };
}
