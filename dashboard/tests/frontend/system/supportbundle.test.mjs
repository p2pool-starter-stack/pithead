import assert from "node:assert/strict";
import { test } from "node:test";

import {
  bundleHref,
  DEFAULT_HOURS,
  runSupportBundle,
  SupportBundlePanel,
} from "../../../mining_dashboard/web/static/system/supportbundle.mjs";
import { render } from "../helpers/render.mjs";

const ID = "22222222-2222-4222-8222-222222222222";
const okResult = (body) => ({ status: 200, ok: true, json: async () => body });

async function withFastPoll(fetchStub, fn) {
  const realFetch = globalThis.fetch;
  const realTimeout = globalThis.setTimeout;
  globalThis.fetch = fetchStub;
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

test("runSupportBundle posts the requested window, skips 'running', returns id + archive", async () => {
  let posted = null;
  let polls = 0;
  const fetchStub = async (url, opts) => {
    if (url === "/api/control/support-bundle") {
      posted = opts;
      return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
    }
    polls++;
    if (polls === 1) return okResult({ status: "running" });
    return okResult({ status: "applied", archive: "support-bundle-x.tar.gz", hours: 24, ts: 1 });
  };
  const out = await withFastPoll(fetchStub, () => runSupportBundle(24));
  assert.equal(out.id, ID);
  assert.equal(out.status, "applied");
  assert.equal(posted.headers["X-Pithead-Control"], "1");
  assert.equal(posted.body, JSON.stringify({ hours: 24 }));
});

test("no stated window sends no hours key — the host states its own default", async () => {
  let body = null;
  const fetchStub = async (url, opts) => {
    if (url === "/api/control/support-bundle") {
      body = opts.body;
      return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
    }
    return okResult({ status: "applied", archive: "a.tar.gz", hours: DEFAULT_HOURS });
  };
  const out = await withFastPoll(fetchStub, () => runSupportBundle(0));
  assert.equal(body, JSON.stringify({}));
  assert.equal(out.hours, DEFAULT_HOURS);
});

test("a host rejection arrives as the outcome, not a throw", async () => {
  const fetchStub = async (url) =>
    url === "/api/control/support-bundle"
      ? { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) }
      : okResult({ status: "rejected", error: "a support bundle was collected less than a minute ago" });
  const out = await withFastPoll(fetchStub, () => runSupportBundle(72));
  assert.equal(out.status, "rejected");
});

test("bundleHref carries the id url-encoded to the download route", () => {
  assert.equal(bundleHref(ID), `/api/control/support-bundle-download?id=${ID}`);
});

test("idle card states the default window and the off card defers to Configuration", () => {
  const on = render(SupportBundlePanel, { enabled: true });
  assert.match(on, /Collect support bundle/);
  assert.match(on, /value="72"/);
  const off = render(SupportBundlePanel, { enabled: false });
  assert.match(off, /control channel/);
  assert.doesNotMatch(off, /Collect support bundle/);
});
