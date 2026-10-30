export const PAGES = {
  overview: ["Overview", "Is it healthy and am I earning?", "inspect"],
  machines: ["Machines", "Are my rigs mining, and how do I add one?", "pool-and-rigs"],
  earnings: ["Earnings", "What have I earned and what should I expect?", "earnings"],
  settings: ["Settings", "Change how Pithead runs.", "node-and-network"],
};

export const SECTIONS = {
  "node-and-network": "Node and network",
  "pool-and-rigs": "Pool and rigs",
  payout: "Payout",
  access: "Access",
  "remote-access": "Remote access over Tor",
  alerts: "Alerts detail",
  earnings: "Earnings",
  maintenance: "Maintenance",
  inspect: "Inspect",
  activity: "Activity",
  appearance: "Appearance",
  "update-details": "Update details",
  backup: "Backup",
  "configuration-json": "Configuration JSON",
};

export function readRoute(url, preference = "simple") {
  const params = url.searchParams;
  const legacy = params.get("view") || preference;
  const page = Object.hasOwn(PAGES, params.get("page"))
    ? params.get("page")
    : ["config", "backup"].includes(legacy)
      ? "settings"
      : "overview";
  const section = params.get("advanced");
  const advanced = Object.hasOwn(SECTIONS, section)
    ? section
    : !params.has("page")
      ? { advanced: "inspect", config: "configuration-json", backup: "backup" }[legacy] || null
      : null;
  return { page, advanced };
}

export function routeUrl(url, page, advanced = null) {
  const next = new URL(url);
  next.searchParams.delete("view");
  next.searchParams.set("page", Object.hasOwn(PAGES, page) ? page : "overview");
  if (Object.hasOwn(SECTIONS, advanced)) next.searchParams.set("advanced", advanced);
  else next.searchParams.delete("advanced");
  return next;
}

export function createNavigation({ win, preference, dirty = () => false, onChange }) {
  let current = new URL(win.location.href);
  let route = readRoute(current, preference);
  let index = Number.isSafeInteger(win.history.state?.pitheadIndex)
    ? win.history.state.pitheadIndex
    : 0;
  let restoring = false;
  win.history.replaceState({ ...win.history.state, pitheadIndex: index }, "", current);
  const permitted = () => !dirty() || win.confirm("Leave this page with unsaved changes?");
  const accept = (url) => {
    current = url;
    route = readRoute(url);
    onChange(route);
  };
  const pop = (event) => {
    if (restoring) {
      restoring = false;
      return;
    }
    const nextIndex = Number.isSafeInteger(event.state?.pitheadIndex)
      ? event.state.pitheadIndex
      : index - 1;
    if (permitted()) {
      index = nextIndex;
      accept(new URL(win.location.href));
    } else {
      restoring = true;
      win.history.go(index - nextIndex);
    }
  };
  const unload = (event) => {
    if (dirty()) {
      event.preventDefault();
      event.returnValue = "";
    }
  };
  win.addEventListener("popstate", pop);
  win.addEventListener("beforeunload", unload);
  return {
    route,
    go(page, advanced = null) {
      if (!permitted()) return false;
      const next = routeUrl(current, page, advanced);
      index++;
      win.history.pushState({ pitheadIndex: index }, "", next);
      accept(next);
      return true;
    },
    close() {
      win.removeEventListener("popstate", pop);
      win.removeEventListener("beforeunload", unload);
    },
  };
}
