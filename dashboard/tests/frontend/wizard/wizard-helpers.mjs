import { WizardApp } from "../../../mining_dashboard/web/static/wizard/wizard.mjs";

const DISKS = [
  { name: "nvme0n1", size: "931.5G", model: "Samsung SSD 990", serial: "S6P1NF0T", state: "empty" },
  { name: "sda", size: "3.6T", model: "WDC WD40EFRX", serial: "WD-WCC7K3", state: "pithead-with-data" },
];

// --- app orchestration --------------------------------------------------------------------
// THE gap these tests exist to close. Three bench-visible defects lived in the app's fetch
// orchestration, and nothing covered that layer: pytest proved the endpoints, the render probes
// above prove a view given its props, and between them sat "does the app ask for the right
// thing and render what comes back". The credentials card could never appear for two whole
// releases because submit() read a stage its own setState had not applied yet.

function stubSetState(inst) {
  inst.setState = (patch) => {
    const next = typeof patch === "function" ? patch(inst.state, inst.props) : patch;
    Object.assign(inst.state, next);
  };
}

// A server whose /api/wizard-state answers are scripted per call, so a stage TRANSITION can be
// asserted rather than a single snapshot.
function stubServer(states) {
  const real = globalThis.fetch;
  let i = 0;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/api/wizard-state")) {
      const s = states[Math.min(i++, states.length - 1)];
      return { ok: true, status: 200, json: async () => s };
    }
    if (String(url).includes("/status")) return { ok: true, text: async () => "Working…" };
    return { ok: true, status: 200, json: async () => ({}), text: async () => "" };
  };
  return () => {
    globalThis.fetch = real;
  };
}

const REF = { monero: { wallet_address: "", prune: true }, p2pool: { pool: "mini" } };

const stateFor = (stage, extra = {}) => ({
  stage,
  mode: stage === "installer" ? "installer" : "setup",
  config: REF,
  reference: REF,
  error: null,
  disks: [],
  handoff: null,
  ...extra,
});

async function appOn(states) {
  const inst = new WizardApp({});
  stubSetState(inst);
  // poll() re-arms itself on a timer; left live it keeps node alive forever and couples every
  // assertion to a background loop. The loop's own behaviour is asserted by driving loadState
  // directly, which is all poll() does.
  inst.poll = () => {};
  const restore = stubServer(states);
  await inst.loadState();
  return { inst, restore };
}

export { DISKS, REF, appOn, stateFor, stubServer, stubSetState };
