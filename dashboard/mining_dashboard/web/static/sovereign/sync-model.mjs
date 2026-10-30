const finite = (value) => typeof value === "number" && Number.isFinite(value) && value >= 0;

export function estimate(chain, samples) {
  if (chain?.state === "done") return 0;
  if (!finite(chain?.target) || chain.target <= 0 || !finite(chain.current)) return null;
  const recent = samples.filter((sample) => sample.target === chain.target);
  if (recent.length < 3) return null;
  const first = recent[0],
    last = recent.at(-1);
  if (last.current <= first.current || last.at <= first.at) return null;
  if (recent.some((sample, i) => i && sample.current <= recent[i - 1].current)) return null;
  return Math.ceil(
    (Math.max(0, chain.target - chain.current) * (last.at - first.at)) /
      (last.current - first.current),
  );
}

export function duration(seconds) {
  if (!finite(seconds)) return "unknown";
  if (seconds < 60) return "less than a minute";
  const minutes = Math.ceil(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  if (minutes < 1440) return `${Math.ceil(minutes / 60)} hours`;
  return `${Math.ceil(minutes / 1440)} days`;
}

export function needsSync(state) {
  const chains = state?.sync_status?.chains;
  const mining = state?.sync_status?.mining;
  return (
    state?.syncing === true ||
    Object.values(chains || {}).some(
      (chain) =>
        chain?.synced === false ||
        chain?.reachable === false ||
        chain?.down === true ||
        ["red", "amber"].includes(chain?.health?.level),
    ) ||
    mining?.held === true ||
    mining?.workers_rejected === true ||
    mining?.fail_closed === true ||
    mining?.released === false
  );
}

export function admission(state) {
  const mining = state?.sync_status?.mining;
  if (!mining) return "Mining admission unknown";
  if (mining.fail_closed) return "Mining held by the host's fail-closed health policy";
  if (mining.workers_rejected)
    return "Workers waiting for required nodes to stay healthy through the recovery window, then worker re-admission";
  if (mining.held || !mining.released) {
    const chains = state.sync_status?.chains;
    const ready = (name) => chains?.[name]?.reachable === true && chains?.[name]?.synced === true;
    if (ready("monero") && (!state.tari_gates_sync || ready("tari")))
      return "Required nodes are synced; waiting for the host to start required services and admit mining";
    return state.tari_gates_sync
      ? "Mining waiting for Monero and required Tari to sync; the host then starts the required services"
      : state.sync_status?.chains?.tari
        ? "Mining waiting for Monero to sync; optional Tari does not hold the first release"
        : "Mining waiting for Monero to sync; the host then starts the required services";
  }
  return "Mining admitted by the host; this is not proof of accepted mining work";
}

export function createSyncHistory(storage) {
  let snapshot = null;
  const samples = {};
  try {
    const saved = JSON.parse(storage?.getItem("pitheadSyncSnapshot") || "null");
    if (saved?.snapshot?.sync && finite(saved.snapshot.sync_status?.sampled_at)) {
      snapshot = saved.snapshot;
      for (const name of ["monero", "tari"])
        samples[name] = Array.isArray(saved.samples?.[name])
          ? saved.samples[name]
              .filter(
                (point) =>
                  point && finite(point.at) && finite(point.current) && finite(point.target),
              )
              .slice(-12)
          : [];
    }
  } catch {}
  return {
    get snapshot() {
      return snapshot;
    },
    observe(state) {
      const at = state?.sync_status?.sampled_at;
      if (!finite(at)) return;
      for (const name of ["monero", "tari"]) {
        const chain = state.sync?.[name];
        const identity =
          state.sync_status.chains?.[name]?.node ?? state.sync_status.chains?.[name]?.local;
        let history = Array.isArray(samples[name]) ? samples[name] : [];
        if (
          history.some(
            (point) =>
              point.identity !== identity ||
              point.target !== chain?.target ||
              point.current > chain?.current,
          )
        )
          history = [];
        if (finite(chain?.current) && finite(chain?.target) && at > (history.at(-1)?.at ?? 0))
          history.push({ at, current: chain.current, target: chain.target, identity });
        samples[name] = history.filter((point) => at - point.at <= 300).slice(-12);
      }
      snapshot = {
        sync: state.sync,
        sync_status: state.sync_status,
        syncing: state.syncing,
        tari_gates_sync: state.tari_gates_sync,
        profile: state.profile,
        last_update: state.last_update,
      };
      try {
        storage?.setItem("pitheadSyncSnapshot", JSON.stringify({ snapshot, samples }));
      } catch {}
    },
    eta(name, chain) {
      return estimate(chain, Array.isArray(samples[name]) ? samples[name] : []);
    },
  };
}
