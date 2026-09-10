import { WorkerInspect } from "../../../mining_dashboard/web/static/workers/workerview.mjs";

const SENTINEL = { __secret__: true };

const DETAIL = {
  name: "rig1",
  found: true,
  editable: true,
  control_enabled: true,
  status: "mining",
  hashrate: "1.2 kH/s",
  rigforge: null,
  writable_keys: ["DONATION", "max_temp_c", "token"],
  last_applied: { DONATION: 5, max_temp_c: 70, token: SENTINEL },
  history: [],
  hashrate_history: { hashrate: [], markers: [] },
};

// WorkerInspect is never mounted here (no DOM/jsdom), so Preact's setState() silently no-ops on
// `state` — its render loop never runs. Stub it to merge synchronously so the methods under test
// (onJsonInput, apply's bookkeeping) are observable.
function stubSetState(inst) {
  inst.setState = (patch) => {
    const next = typeof patch === "function" ? patch(inst.state, inst.props) : patch;
    Object.assign(inst.state, next);
  };
}

function readyInstance(detail = DETAIL) {
  const inst = new WorkerInspect({ name: "rig1", onClose: () => {} });
  stubSetState(inst);
  inst.state = {
    ...inst.state,
    phase: "ready",
    detail,
    editText: JSON.stringify(detail.last_applied, null, 2),
  };
  return inst;
}

export { DETAIL, SENTINEL, readyInstance, stubSetState };
