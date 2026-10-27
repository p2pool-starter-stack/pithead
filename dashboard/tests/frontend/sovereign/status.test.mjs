import assert from "node:assert/strict";
import { test } from "node:test";
import { stackStatus } from "../../../mining_dashboard/web/static/sovereign/status.mjs";

const healthy = {
  syncing: false,
  db_healthy: true,
  monero: { health: { level: "green", status: "At tip, with peers" } },
  badges: [{ text: "P2POOL", variant: "ok" }],
};

test("API green is healthy; unknown health is not a fault or a healthy verdict", () => {
  assert.deepEqual(stackStatus(healthy, true), { text: "Healthy", level: "ok" });
  assert.equal(stackStatus({ ...healthy, monero: { health: { level: "unknown" } } }, true).text, "Health unknown");
});

test("normal sync and its miner hold remain synchronization rather than faults", () => {
  const state = { ...healthy, syncing: true, sync: { monero: { percent: 42 } },
    monero: { health: { level: "unknown" } }, badges: [
      { text: "Syncing...", variant: "warn" },
      { text: "Miner held (sync)", variant: "warn" },
    ] };
  assert.equal(stackStatus(state, true).text, "Syncing 42%");
  assert.equal(stackStatus({ ...state, sync: { monero: { percent: 0 } } }, true).text, "Syncing 0%");
  assert.equal(stackStatus({ ...state, sync: {} }, true).text, "Syncing — progress unknown");
});

test("DB badges and persistence flags count the same condition once, including during sync", () => {
  for (const text of ["⚠ DB write failing", "DB write failing"]) {
    const state = { ...healthy, db_healthy: false, badges: [{ text, variant: "bad" }] };
    assert.equal(stackStatus(state, true).text, "Needs attention 1");
    assert.equal(stackStatus({ ...state, syncing: true, badges: [...state.badges, { text: "Syncing...", variant: "warn" }] }, true).text, "Needs attention 1");
  }
  assert.equal(stackStatus({ ...healthy, db_healthy: false }, true).text, "Needs attention 1");
});

test("resource bars do not duplicate API warnings; distinct conditions remain distinct", () => {
  const disk = { text: "⚠ Disk 95% full", variant: "bad" };
  const memory = { text: "⚠ Memory pressure (0.3 GB free)", variant: "warn" };
  const lowRam = { text: "⚠ Low RAM (4 GB)", variant: "warn" };
  assert.equal(stackStatus({ ...healthy, system: { disk: { level: "high" } }, badges: [disk] }, true).text, "Needs attention 1");
  assert.equal(stackStatus({ ...healthy, system: { mem: { level: "high" } }, badges: [memory] }, true).text, "Needs attention 1");
  const state = { ...healthy, system: { mem: { level: "high" }, disk: { level: "high" } } };
  assert.equal(stackStatus({ ...state, badges: [disk, disk, memory, lowRam] }, true).text, "Needs attention 3");
});

test("red Monero health and its node badge count once alongside independent faults", () => {
  const state = { ...healthy, monero: { health: { level: "red" } } };
  assert.equal(stackStatus(state, true).text, "Needs attention 1");
  for (const text of ["Monero chain unhealthy", "monerod DOWN"]) {
    assert.equal(stackStatus({ ...state, badges: [{ text, variant: "bad" }] }, true).text, "Needs attention 1");
    assert.equal(stackStatus({ ...state, db_healthy: false, badges: [{ text, variant: "bad" }] }, true).text, "Needs attention 2");
  }
});

test("nonblocking Tari sync is informational while Monero mining is healthy", () => {
  for (const text of ["Tari syncing", "Tari syncing 55%"])
    assert.equal(stackStatus({ ...healthy, badges: [{ text, variant: "warn" }] }, true).text, "Healthy");
});

test("sync progress follows unfinished chains and does not invent a loading percentage", () => {
  const state = { ...healthy, syncing: true, badges: [{ text: "Syncing...", variant: "warn" }] };
  assert.equal(stackStatus({ ...state, sync: { monero: { state: "done", percent: 100 }, tari: { state: "syncing", percent: 42 } } }, true).text, "Syncing 42%");
  assert.equal(stackStatus({ ...state, sync: { monero: { state: "syncing", percent: 58 }, tari: { state: "syncing", percent: 42 } } }, true).text, "Syncing 42%");
  assert.equal(stackStatus({ ...state, sync: { monero: { state: "syncing", percent: 58 }, tari: { state: "loading", percent: 0 } } }, true).text, "Syncing — progress unknown");
});

test("a malformed warning label still reports attention rather than breaking rendering", () => {
  assert.equal(stackStatus({ ...healthy, badges: [{ variant: "bad" }] }, true).text, "Needs attention 1");
});

test("a bad verdict is not hidden by an informational-looking label", () => {
  assert.equal(stackStatus({ ...healthy, badges: [{ text: "Syncing...", variant: "bad" }] }, true).text, "Needs attention 1");
});

test("Tari sync failures are not mistaken for ordinary progress", () => {
  assert.equal(stackStatus({ ...healthy, badges: [{ text: "Tari syncing failed", variant: "warn" }] }, true).text, "Needs attention 1");
});
