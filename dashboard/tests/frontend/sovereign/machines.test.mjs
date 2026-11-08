import assert from "node:assert/strict";
import { test } from "node:test";
import { html } from "../../../mining_dashboard/web/static/app/preact.mjs";
import { detailSnapshot } from "../../../mining_dashboard/web/static/workers/workerlogic.mjs";
import { earningsWording } from "../../../mining_dashboard/web/static/sovereign/earnings-control.mjs";
import { ConnectCard, MachinesPage } from "../../../mining_dashboard/web/static/sovereign/machines.mjs";
import { RigInspector } from "../../../mining_dashboard/web/static/sovereign/machines-inspector.mjs";
import { findRig, localMinerAvailable, rigHealth, rigRows, rigSettings, rigSummary, rigView } from "../../../mining_dashboard/web/static/sovereign/machines-model.mjs";
import { rigFleet } from "../fixtures/rigs.mjs";
import { render, renderToString } from "../helpers/render.mjs";

const platforms = {
  appliance: { control_enabled: true, os_update: {} },
  "diy-login": { control_enabled: true, os_update: null },
  "diy-readonly": { control_enabled: false, os_update: null },
};

test("offline and silent rigs never read as a healthy zero; unmanaged mining rigs are quiet", () => {
  assert.deepEqual(
    (({ status, note, attention, hashrate }) => ({ status, note, attention, hashrate }))(rigView({ name: "a", status: "offline", h60: 0, adopted: true })),
    { status: "Offline", note: null, attention: true, hashrate: "Offline" },
  );
  const silent = rigView({ name: "b", status: "online", h60: 0, adopted: true });
  assert.equal(silent.hashrate, "Unavailable");
  assert.equal(silent.note, "Hashrate unavailable");
  assert.equal(silent.attention, true);
  assert.equal(rigView({ name: "c", status: "online", h60: "bad" }).hashrate, "Unavailable");
  const unmanaged = rigView({ name: "d", status: "online", h60: 2500, adopted: false });
  assert.deepEqual([unmanaged.status, unmanaged.note, unmanaged.attention, unmanaged.hashrate], ["Mining", "unmanaged", false, "2.50 kH/s"]);
  assert.equal(rigView({ name: "f", status: "online", h60: 0 }).note, "Hashrate unavailable · unmanaged");
  const behind = rigView({ name: "e", status: "online", h60: 2500, adopted: true, rigforge: { version: "0.9.0" }, rigforge_update: { available: true, latest: "1.0.0" } });
  assert.deepEqual([behind.status, behind.attention, behind.version, behind.latest], ["Behind", true, "0.9.0", "1.0.0"]);
});

test("rigs order attention first then name, stable for duplicate names, with find and sort", () => {
  const workers = [
    { name: "zeta", status: "online", h60: 10, adopted: true, marker: 0 },
    { name: "dup", status: "online", h60: 30, adopted: true },
    { name: "alpha", status: "offline", h60: 0 },
    { name: "dup", status: "online", h60: 20, adopted: true },
    { name: "beta", status: "online", h60: 5, adopted: true, rigforge_update: { available: true } },
  ];
  assert.deepEqual(rigRows(workers).map((row) => [row.name, row.index]), [["alpha", 2], ["beta", 4], ["dup", 1], ["dup", 3], ["zeta", 0]]);
  assert.deepEqual(rigRows(workers, { sort: "hashrate" }).map((row) => row.index), [1, 3, 0, 4, 2]);
  assert.deepEqual(rigRows(workers, { find: " DU " }).map((row) => row.index), [1, 3]);
  assert.deepEqual(rigRows(null), []);
  assert.equal(rigSummary(workers), "4 of 5 mining");
  assert.equal(rigSummary([...workers, { name: "silent", status: "online", h60: 0, adopted: true }]), "4 of 6 mining");
  assert.deepEqual(rigRows(workers).filter((row) => row.name === "dup").map((row) => row.key), ["0:dup", "1:dup"]);
  assert.equal(findRig(workers, "dup", 1), workers[3]);
  assert.equal(findRig([workers[3], workers[1]], "dup", 1), workers[1]);
  assert.equal(findRig(null, "dup", 0), undefined);
});

test("one copy carries the pool address and the password only when set", () => {
  assert.equal(rigSettings({ url: "stratum+tcp://pool.test:3333", password_set: true, password: "pw" }), "Pool: stratum+tcp://pool.test:3333\nPassword: pw");
  assert.equal(rigSettings({ url: "stratum+tcp://pool.test:3333", password_set: false, password: "" }), "Pool: stratum+tcp://pool.test:3333");
  assert.equal(rigSettings(null), null);
});

class Loaded extends ConnectCard {
  constructor(props) {
    super(props);
    this.state = { connection: props.connection, status: "" };
  }
}

test("the connect card shows the password in clear, one copy and TLS whenever the listener reports it", () => {
  const plain = render(Loaded, { connection: { url: "stratum+tcp://pool.test:3333", password_set: true, password: "pw" } });
  assert.match(plain, /<code>pw<\/code>/);
  assert.equal((plain.match(/<button/g) || []).length, 1);
  assert.match(plain, /Copy rig settings/);
  assert.doesNotMatch(plain, /Reveal|Hide|Copy password|fingerprint/);
  const tls = render(Loaded, { connection: { url: "stratum+ssl://pool.test:3333", password_set: false, tls: true, fingerprint: "AB:CD" } });
  assert.match(tls, /None set/);
  assert.match(tls, /Certificate fingerprint/);
  assert.match(tls, /AB:CD/);
  assert.match(render(Loaded, { connection: { url: "u", tls: true } }), /Unavailable: apply the configuration again/);
});

test("copy writes the pool address and password, and an expired session hides the password", async () => {
  const written = [];
  const original = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: { clipboard: { writeText: async (text) => written.push(text) } } });
  try {
    const card = new Loaded({ connection: { url: "stratum+tcp://pool.test:3333", password_set: true, password: "pw" } });
    card.setState = (next) => Object.assign(card.state, next);
    await card.copy();
    assert.deepEqual(written, ["Pool: stratum+tcp://pool.test:3333\nPassword: pw"]);
    assert.equal(card.state.status, "Rig settings copied.");
    globalThis.navigator.clipboard.writeText = async () => { throw new Error("denied"); };
    await card.copy();
    assert.match(card.state.status, /Copy is unavailable/);
  } finally {
    if (original) Object.defineProperty(globalThis, "navigator", original);
    else delete globalThis.navigator;
  }
  const expired = render(Loaded, { writable: false, connection: { url: "u", password_set: true, password: "pw" } });
  assert.doesNotMatch(expired, /pw|Copy rig settings/);
  assert.match(expired, /Hidden until you sign in again/);
  assert.match(render(Loaded, { writable: false, connection: { url: "u", password_set: false } }), /Copy rig settings/);
});

test("platform fixtures: appliance offers Also mine on this box, DIY never, and no Update all slot", () => {
  for (const [platform, extra] of Object.entries(platforms)) {
    const out = render(MachinesPage, { state: { ...extra, workers: rigFleet(2) } });
    assert.equal(/Also mine on this box/.test(out), platform === "appliance", platform);
    assert.equal(localMinerAvailable(extra), platform === "appliance");
    assert.doesNotMatch(out, /Update all/);
  }
  const disconnected = render(MachinesPage, { state: { ...platforms.appliance, workers: [] }, connected: false });
  assert.doesNotMatch(disconnected, /Also mine on this box/);
  assert.match(disconnected, /No rigs have connected yet/);
  assert.match(render(MachinesPage, { state: null }), /Waiting for rig data/);
});

test("2, 50 and 100 rig fixtures keep find, sort and columns inside Advanced", () => {
  for (const count of [2, 50, 100]) {
    const out = render(MachinesPage, { state: { ...platforms["diy-login"], workers: rigFleet(count) } });
    const [outside, rest] = out.split('<details class="list-advanced">');
    assert.ok(rest, `${count} rigs render the list Advanced section`);
    assert.doesNotMatch(outside, /<select|<input/);
    assert.match(rest.split("</details>")[0], /Find a rig.*Sort by.*Show shares and version/s);
    assert.equal((out.match(/class="rig-row/g) || []).length, count);
    assert.doesNotMatch(out, /rig-rate">0(\.00)? H\/s/);
  }
});

class Ready extends RigInspector {
  constructor(props) {
    super(props);
    Object.assign(this.state, { phase: "ready", detail: props.detail, editText: JSON.stringify(detailSnapshot(props.detail), null, 2) });
  }
}
const detail = (extra = {}) => ({
  control_enabled: true, editable: true, ip: null, writable_keys: ["DONATION"], last_applied: {}, rig_config: { DONATION: 1 },
  rigforge: { version: "0.9.0" }, rigforge_update: { available: true, latest: "1.0.0", url: "https://example.test/r" },
  hashrate_history: { hashrate: [{ x: 1000, y: 100 }, { x: 2000, y: 300 }, { x: 3000, y: 0 }], markers: [{ x: 1500 }] },
  history: [{ ts: 1 }], hashrate_by_config: [{ version: 1 }], ...extra,
});
const inspect = (extra = {}, worker = { name: "rig", status: "online", h60: 100, adopted: true, accepted_str: "7", rejected_str: "1" }) =>
  renderToString(html`<${Ready} name="rig" writable=${extra.writable ?? true} shared=${extra.shared ?? 1} worker=${worker} detail=${detail(extra)} />`);

test("the inspector shows health outside Advanced and no chart ranges or change history", () => {
  assert.deepEqual(rigHealth(detail()), { average: "133.33 H/s", lastSeen: 2000 });
  assert.deepEqual(rigHealth({}), { average: null, lastSeen: null });
  const out = inspect();
  const [health, advanced] = out.split('<details class="rig-advanced">');
  for (const label of ["Status", "Last seen mining", "Software", "24 h hashrate", "Accepted shares", "Rejected shares"]) assert.match(health, new RegExp(label));
  assert.match(health, /RigForge 0.9.0 · 1.0.0 available/);
  assert.match(health, /133.33 H\/s average/);
  assert.doesNotMatch(health, /<button(?![^>]*>Close)/);
  assert.doesNotMatch(out, />24h<|>1w<|>All<|History|Hashrate by config/);
  assert.match(advanced, /Update this rig.*Upgrade rig….*Table.*JSON.*Apply to rig/s);
  const json = renderToString(html`<${class extends Ready { constructor(props) { super(props); this.state.mode = "json"; } }} name="rig" writable=${true} worker=${{ name: "rig" }} detail=${detail()} />`);
  assert.match(json, /Rig configuration JSON.*Load from file/s);
});

test("the inspector offers only the controls the rig is authorized for", () => {
  assert.match(inspect({ control_enabled: false }), /Rig control is off/);
  const unmanaged = inspect({ editable: false });
  assert.match(unmanaged, /Manage this rig/);
  assert.doesNotMatch(unmanaged, /Apply to rig|Upgrade rig/);
  assert.match(inspect({ rigforge_update: null }), /on the latest release it reports/);
  const shared = inspect({ shared: 2 });
  assert.match(shared, /2 rigs report the name rig/);
  assert.doesNotMatch(shared, /Apply to rig|Upgrade rig|Manage this rig/);
  const dirtyOffline = renderToString(html`<${class extends Ready { constructor(props) { super(props); this.state.tableEdits = { DONATION: "2" }; } }} name="rig" writable=${false} shared=${1} worker=${{ name: "rig" }} detail=${detail()} />`);
  assert.match(dirtyOffline, /<button type="button" disabled>Apply to rig<\/button>.*Rig changes are unavailable while disconnected or signed out/s);
  assert.match(dirtyOffline, /New RigForge release 1.0.0 available/);
  assert.doesNotMatch(dirtyOffline, /Unsaved/);
  assert.doesNotMatch(dirtyOffline, /Upgrade rig/);
  const dirtyShared = renderToString(html`<${class extends Ready { constructor(props) { super(props); this.state.tableEdits = { DONATION: "2" }; } }} name="rig" writable=${true} shared=${2} worker=${{ name: "rig" }} detail=${detail()} />`);
  assert.match(dirtyShared, /<button type="button" disabled>Apply to rig<\/button>.*Give each rig its own name/s);
  assert.doesNotMatch(dirtyShared, /Upgrade rig/);
  const offline = inspect({ writable: false });
  assert.match(offline, /unavailable while disconnected or signed out/);
  assert.doesNotMatch(offline, /Apply to rig|Upgrade rig|Manage this rig/);
  assert.match(inspect({ rigforge_update: { available: true, latest: "1.0.0", url: null } }), /1.0.0 is available, but its release page is not reported/);
  assert.match(inspect({ rigforge: null, rigforge_update: null }), /Not reported: this rig does not publish a RigForge version/);
  assert.match(inspect({ hashrate_history: { hashrate: [] } }), /Not recorded in the last 24 hours.*24 h hashrate<\/dt><dd>Unavailable/s);
});

test("a poll refreshes the inspector quietly, never over an edit, and an adopt keeps the form mounted", async () => {
  const fetched = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url) => {
    fetched.push(url);
    return { ok: true, json: async () => detail({ editable: true, rigforge: { version: "1.0.0" } }) };
  };
  try {
    const inspector = new Ready({ name: "rig a", worker: { name: "rig a" }, detail: detail({ editable: false }) });
    inspector.state.editText = JSON.stringify({ DONATION: 1 }, null, 2);
    inspector.setState = (next) => Object.assign(inspector.state, typeof next === "function" ? next(inspector.state) : next);
    inspector.props = { ...inspector.props, worker: { name: "rig a", h60: 2 } };
    inspector.componentDidUpdate({ worker: { name: "rig a" } });
    await new Promise((resolve) => setTimeout(resolve));
    assert.deepEqual(fetched, ["/api/worker?name=rig%20a&range=24h"]);
    assert.equal(inspector.state.phase, "ready");
    assert.equal(inspector.state.detail.rigforge.version, "1.0.0");
    inspector.state.tableEdits = { DONATION: "2" };
    inspector.componentDidUpdate({ worker: { name: "rig a" } });
    await inspector.load(true);
    assert.deepEqual(inspector.state.tableEdits, { DONATION: "2" });
    await inspector.load();
    assert.deepEqual(inspector.state.tableEdits, {});
    globalThis.fetch = async () => ({ ok: false, status: 502 });
    inspector.state.tableEdits = {};
    await inspector.load(true);
    assert.equal(inspector.state.stale, true);
    inspector.state.stale = false;
    await inspector.load();
    assert.equal(inspector.state.stale, true);
    assert.match(renderToString(inspector.render()), /could not be refreshed/);
    globalThis.fetch = async (url) => {
      fetched.push(url);
      return { ok: true, json: async () => detail() };
    };
    inspector.state.tableEdits = { DONATION: "9" };
    inspector.props = { ...inspector.props, shared: 1 };
    inspector.componentDidUpdate({ worker: inspector.props.worker, shared: 2 });
    await new Promise((resolve) => setTimeout(resolve));
    assert.deepEqual(inspector.state.tableEdits, {});
    assert.doesNotMatch(renderToString(inspector.render()), /could not be refreshed/);
  } finally {
    globalThis.fetch = original;
  }
});

test("the local miner switch reads in plain words in the host review", () => {
  assert.equal(earningsWording("local_miner.enabled changed"), "Also mine on this box changed");
});
