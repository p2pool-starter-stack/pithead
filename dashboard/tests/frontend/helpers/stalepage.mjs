import { installFreshness } from "../../../mining_dashboard/web/static/app/freshness.mjs";

export const STALE = "Pithead restarted or the page is out of date. Reloading…";

export function installStaleProbe() {
  const reloads = [];
  const session = {};
  installFreshness({
    reload: () => reloads.push(1),
    store: {
      getItem: (k) => session[k] ?? null,
      setItem: (k, v) => {
        session[k] = String(v);
      },
    },
    fetchFn: async () => ({ ok: true }),
    sleep: async () => {},
  });
  return { reloads, settle: () => new Promise((r) => setImmediate(r)) };
}

export async function withFetch(stub, fn) {
  const realFetch = globalThis.fetch;
  const realTimeout = globalThis.setTimeout;
  globalThis.fetch = stub;
  globalThis.setTimeout = (cb) => {
    cb();
    return 0;
  };
  try {
    return await fn();
  } finally {
    globalThis.fetch = realFetch;
    globalThis.setTimeout = realTimeout;
  }
}

export const reply = (status, text = "", json = {}) => ({
  status,
  ok: status >= 200 && status < 300,
  text: async () => text,
  json: async () => json,
});
