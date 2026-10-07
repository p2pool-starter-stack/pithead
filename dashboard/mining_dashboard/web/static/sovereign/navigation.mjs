// Hash routes leave the existing range/zoom query contract intact and give native history.
export const PAGES = [
  ["overview", "Overview", "Your corner of the network."],
  ["machines", "Your machines", "Every worker, part of your operation."],
  ["earnings", "Earnings", "What you have earned. What you can expect."],
  ["network", "Network", "Understand the connections behind your mining."],
  ["activity", "Activity", "The record of your operation."],
  ["settings", "Settings", "Your stack. Your decisions."],
  ["maintenance", "Maintenance", "Keep your operation in good shape."],
  ["help", "Help", "A clear next step, when you need one."],
];

export function routePage(hash, saved = "simple") {
  const id = hash.replace(/^#/, "");
  const aliases = {
    simple: "overview",
    advanced: "network",
    config: "settings",
    backup: "maintenance",
  };
  if (PAGES.some(([page]) => page === id)) return id;
  return aliases[id] || (!id && aliases[saved]) || "overview";
}

export function miningStatus(state, connected) {
  if (!connected) return { label: "Disconnected · stale data", tone: "warn" };
  if (!state) return { label: "Connecting", tone: "muted" };
  if (state.syncing) return { label: "Waiting for node sync", tone: "warn" };
  const workers = state.workers || [];
  if (workers.some((w) => w.status === "online" && w.h60 > 0))
    return { label: "Mining activity reported", tone: "ok" };
  return { label: workers.length ? "No hashrate reported" : "No workers connected", tone: "muted" };
}

export const ICONS = {
  overview: "M3 10 12 3l9 7v11h-6v-7H9v7H3Z",
  machines: "M3 4h18v13H3ZM8 21h8m-4-4v4",
  earnings: "M5 21V13m7 8V3m7 18V8",
  network: "M12 4 4 19h16ZM12 4v9m-8 6 8-6 8 6",
  activity: "M8 5h13M8 12h13M8 19h13M3 5h.01M3 12h.01M3 19h.01",
  settings:
    "m9 3-1 3-3 1v4l-2 1 2 1v4l3 1 1 3h6l1-3 3-1v-4l2-1-2-1V7l-3-1-1-3ZM9 12a3 3 0 1 0 6 0 3 3 0 1 0-6 0",
  maintenance: "m14 6 4-4a6 6 0 0 1-7 8L4 20l-3-3 10-7a6 6 0 0 1 3-8Z",
  help: "M9 9a3 3 0 1 1 5 2c-2 1-2 2-2 3m0 3h.01M22 12a10 10 0 1 1-20 0 10 10 0 1 1 20 0",
};
