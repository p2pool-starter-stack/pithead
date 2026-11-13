export const UPDATED_MESSAGE = "Pithead was updated or restarted. Reloading…";
export const STALE_MESSAGE = "Pithead restarted or the page is out of date. Reloading…";
export const RELOAD_GUARD_MS = 120000;
export const GUARD_KEY = "pitheadAutoReloadAt";
const RECONNECT_MS = 2000;
const RECONNECT_MAX = 300;

export function createFreshness({
  reload = () => window.location.reload(),
  store = {
    getItem: (k) => sessionStorage.getItem(k),
    setItem: (k, v) => sessionStorage.setItem(k, v),
  },
  fetchFn = (url, opts) => fetch(url, opts),
  now = () => Date.now(),
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  onChange = () => {},
} = {}) {
  let firstVersion = null;
  let message = null;
  let holds = 0;
  let wanted = false;
  let reloaded = false;
  let waiting = false;

  function show(text) {
    if (message === text) return;
    message = text;
    onChange();
  }

  function recentlyReloaded() {
    try {
      const elapsed = now() - (Number(store.getItem(GUARD_KEY)) || 0);
      return elapsed >= 0 && elapsed < RELOAD_GUARD_MS;
    } catch {
      return false;
    }
  }

  function stamp() {
    try {
      store.setItem(GUARD_KEY, String(now()));
    } catch {
      return;
    }
  }

  function attempt() {
    if (reloaded || holds > 0 || recentlyReloaded()) return;
    stamp();
    reloaded = true;
    reload();
  }

  function request(text) {
    show(text);
    wanted = true;
    attempt();
  }

  function goodPoll(version, recovered) {
    if (firstVersion === null && version) firstVersion = version;
    if (recovered || (version && version !== firstVersion)) request(UPDATED_MESSAGE);
    else if (wanted) attempt();
  }

  async function reportPageStale() {
    show(STALE_MESSAGE);
    if (waiting) return;
    waiting = true;
    try {
      for (let i = 0; i < RECONNECT_MAX && !reloaded; i++) {
        const answered = await fetchFn("/api/state?range=1h", {
          signal: AbortSignal.timeout(10000),
        }).then(
          (res) => res.ok,
          () => false,
        );
        if (answered) {
          wanted = true;
          attempt();
          if (reloaded || holds > 0) return;
        }
        await sleep(RECONNECT_MS);
      }
    } finally {
      waiting = false;
    }
  }

  return {
    goodPoll,
    reportPageStale,
    hold: () => {
      holds++;
    },
    release: () => {
      holds = Math.max(0, holds - 1);
      if (holds === 0 && wanted) attempt();
    },
    message: () => message,
  };
}

let current = createFreshness();
export const installFreshness = (deps) => (current = createFreshness(deps));
export const reportPageStale = () => current.reportPageStale();
export const holdAutoReload = () => current.hold();
export const releaseAutoReload = () => current.release();
export function holdWhile(owner, busy) {
  if (!!owner.holding === busy) return;
  owner.holding = busy;
  if (busy) current.hold();
  else current.release();
}
