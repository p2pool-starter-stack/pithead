import assert from "node:assert/strict";
import { test } from "node:test";
import { createPolling } from "../../../mining_dashboard/web/static/sovereign/polling.mjs";

test("failed, expired and unreadable polls retain the last successful snapshot and recover", async () => {
  let response = { ok: true, json: async () => ({ last_update: "earlier", hashrate: 0 }) };
  const observations = [];
  let tick;
  const polling = createPolling({
    fetchFn: async () => response,
    publish: (data) => observations.push(data),
    schedule: (fn, ms) => { tick = fn; assert.equal(ms, 30000); return 7; },
    cancel: (id) => assert.equal(id, 7),
  });
  await polling.tick();
  const first = observations.at(-1).snapshot;
  for (response of [{ ok: false, status: 503 }, { ok: false, status: 401 }, { ok: true, json: async () => [] }]) {
    await tick();
    assert.equal(observations.at(-1).snapshot, first);
    assert.equal(observations.at(-1).connected, false);
    assert.equal(observations.at(-1).sessionExpired, response.status === 401);
  }
  response = { ok: true, json: async () => ({ last_update: "later" }) };
  await tick();
  assert.equal(observations.at(-1).connected, true);
  assert.equal(observations.at(-1).snapshot.last_update, "later");
  polling.close();
});

test("a hung poll is aborted and does not overlap or publish after shutdown", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let calls = 0;
  const observations = [];
  const polling = createPolling({
    fetchFn: (signal) => new Promise((_resolve, reject) => {
      calls++;
      signal.addEventListener("abort", () => reject(new Error("aborted")));
    }),
    publish: (data) => observations.push(data), schedule: () => 1, cancel: () => {},
  });
  const first = polling.tick();
  await polling.tick();
  assert.equal(calls, 1);
  t.mock.timers.tick(25000);
  await first;
  assert.equal(observations.at(-1).connected, false);
  const second = polling.tick();
  polling.close();
  await second;
  assert.equal(observations.length, 1);
});
