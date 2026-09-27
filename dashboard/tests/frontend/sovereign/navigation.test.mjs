import assert from "node:assert/strict";
import { test } from "node:test";

import {
  miningStatus,
  routePage,
} from "../../../mining_dashboard/web/static/sovereign/navigation.mjs";

test("routePage accepts pages and maps classic view aliases", () => {
  assert.equal(routePage("#machines"), "machines");
  assert.equal(routePage("#simple"), "overview");
  assert.equal(routePage("#advanced"), "network");
  assert.equal(routePage("#config"), "settings");
  assert.equal(routePage("#backup"), "maintenance");
  assert.equal(routePage("", "config"), "settings");
  assert.equal(routePage("#unknown"), "overview");
});

test("miningStatus distinguishes unknown, zero, active, syncing, and stale state", () => {
  assert.deepEqual(miningStatus(null, true), { label: "Connecting", tone: "muted" });
  assert.deepEqual(miningStatus({ workers: [] }, true), {
    label: "No workers connected",
    tone: "muted",
  });
  assert.deepEqual(miningStatus({ workers: [{ status: "online", h60: 0 }] }, true), {
    label: "No hashrate reported",
    tone: "muted",
  });
  assert.deepEqual(miningStatus({ workers: [{ status: "online", h60: 1 }] }, true), {
    label: "Mining activity reported",
    tone: "ok",
  });
  assert.deepEqual(miningStatus({ syncing: true }, true), {
    label: "Waiting for node sync",
    tone: "warn",
  });
  assert.deepEqual(miningStatus(null, false), {
    label: "Disconnected · stale data",
    tone: "warn",
  });
});
