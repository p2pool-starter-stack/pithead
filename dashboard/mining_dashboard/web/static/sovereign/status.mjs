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
  const problems = (state.badges || []).filter((badge) =>
    ["bad", "warn"].includes(badge.variant),
  ).length;
  const resources = [state.system?.mem, state.system?.disk].filter(
    (value) => value?.level === "high",
  ).length;
  const count = problems + resources + (state.db_healthy === false ? 1 : 0);
  if (count) return { text: `Needs attention ${count}`, level: "bad" };
  if (state.syncing) {
    const percent = state.sync?.monero?.percent;
    return {
      text: Number.isFinite(percent) ? `Syncing ${percent}%` : "Syncing — progress unknown",
      level: "warn",
    };
  }
  if (!state.monero?.health || state.monero.health.level === "unknown")
    return { text: "Health unknown", level: "unknown" };
  if (state.monero.health.level !== "ok") return { text: "Needs attention 1", level: "bad" };
  return { text: "Healthy", level: "ok" };
}
