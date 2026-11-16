import assert from "node:assert/strict";
import { test } from "node:test";

import {
  bundleHref,
  DEFAULT_HOURS,
  fetchOldest,
  PRESETS,
  reachNote,
  requestWindow,
  runSupportBundle,
  SupportBundlePanel,
} from "../../../mining_dashboard/web/static/system/supportbundle.mjs";
import { manifestZip, readZip } from "../helpers/zip.mjs";
import { render } from "../helpers/render.mjs";

const ID = "22222222-2222-4222-8222-222222222222";
const okResult = (body) => ({ status: 200, ok: true, json: async () => body });
const accepted = { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };

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

test("the helper zip fixture is a real zip whose manifest reads back", () => {
  const files = readZip(
    manifestZip({ since: "2026-11-15T10:00:00Z", until: "2026-11-15T12:00:00Z", oldest: null }),
  );
  assert.deepEqual(Object.keys(files), ["bundle/manifest.json", "bundle/journal/all.log"]);
  assert.equal(JSON.parse(files["bundle/manifest.json"]).window.effective.since, "2026-11-15T10:00:00Z");
});

test("runSupportBundle posts the window, skips 'running' and returns the applied result", async () => {
  let posted = null;
  let polls = 0;
  const fetchStub = async (url, opts) => {
    if (url === "/api/control/support-bundle") {
      posted = opts;
      return accepted;
    }
    assert.equal(url, `/api/control/support-bundle-result?id=${ID}`);
    polls++;
    if (polls === 1) return okResult({ status: "running" });
    return okResult({ status: "applied", archive: "support-bundle-x.zip", since: "a", until: "b" });
  };
  const out = await withFastPoll(fetchStub, () => runSupportBundle({ hours: 24 }));
  assert.equal(out.id, ID);
  assert.equal(out.status, "applied");
  assert.equal(posted.headers["X-Pithead-Control"], "1");
  assert.equal(posted.body, JSON.stringify({ hours: 24 }));
});

test("a 400 from the route becomes an invalid-range error", async () => {
  const fetchStub = async () => ({ status: 400, ok: false, text: async () => "'since' must be an RFC 3339 time string." });
  await assert.rejects(
    withFastPoll(fetchStub, () => runSupportBundle({ since: "x", until: "y" })),
    /Invalid range: 'since' must be/,
  );
});

test("a host rejection arrives as the outcome, not a throw", async () => {
  const fetchStub = async (url) =>
    url === "/api/control/support-bundle"
      ? accepted
      : okResult({ status: "rejected", error: "a support bundle was collected less than a minute ago" });
  const out = await withFastPoll(fetchStub, () => runSupportBundle({ hours: 72 }));
  assert.equal(out.status, "rejected");
});

test("fetchOldest returns the retained start from the range verb and null when unknown", async () => {
  const stub = (result) => async (url, opts) =>
    url === "/api/control/support-bundle-range"
      ? ((assert.equal(opts.headers["X-Pithead-Control"], "1"), accepted))
      : okResult(result);
  assert.equal(
    await withFastPoll(stub({ status: "applied", oldest: "2026-11-10T08:00:00Z" }), fetchOldest),
    "2026-11-10T08:00:00Z",
  );
  assert.equal(await withFastPoll(stub({ status: "applied", oldest: null }), fetchOldest), null);
  assert.equal(await withFastPoll(stub({ status: "rejected" }), fetchOldest), null);
});

test("presets send hours; a custom range sends UTC start and end", () => {
  assert.deepEqual(requestWindow({ preset: 6 }).body, { hours: 6 });
  const now = new Date("2026-11-15T12:00:00Z");
  const out = requestWindow(
    { preset: "custom", since: "2026-11-15T09:00:00Z", until: "2026-11-15T11:00:00Z" },
    now,
  );
  assert.deepEqual(out.body, { since: "2026-11-15T09:00:00Z", until: "2026-11-15T11:00:00Z" });
});

test("an invalid custom range is refused before anything is sent", () => {
  const now = new Date("2026-11-15T12:00:00Z");
  const bad = (since, until) => requestWindow({ preset: "custom", since, until }, now).error;
  assert.match(bad("", "2026-11-15T11:00:00Z"), /both a start and an end/);
  assert.match(bad("2026-11-15T11:00:00Z", "2026-11-15T09:00:00Z"), /start must be before the end/);
  assert.match(bad("2026-11-15T11:00:00Z", "2026-11-15T13:00:00Z"), /cannot be in the future/);
});

test("a range reaching past the oldest retained entry is flagged, one inside it is not", () => {
  const now = new Date("2026-11-15T12:00:00Z");
  const oldest = "2026-11-15T08:00:00Z";
  assert.match(reachNote(oldest, { hours: 6 }, now), /only reach back to 2026-11-15 08:00:00 UTC/);
  assert.equal(reachNote(oldest, { hours: 1 }, now), null);
  assert.match(reachNote(oldest, { since: "2026-11-14T00:00:00Z", until: "x" }, now), /start there/);
  assert.equal(reachNote(null, { hours: 6 }, now), null);
});

test("bundleHref carries the id url-encoded to the download route", () => {
  assert.equal(bundleHref(ID), `/api/control/support-bundle-download?id=${ID}`);
});

test("the card is always available: presets, default window and one export button", () => {
  assert.deepEqual(
    PRESETS.map((p) => p.hours),
    [1, 6, 24, 72, 168],
  );
  assert.equal(DEFAULT_HOURS, 72);
  const html = render(SupportBundlePanel, {});
  assert.match(html, /Export logs/);
  assert.match(html, /Last 72 hours/);
  assert.match(html, /Custom range/);
  assert.doesNotMatch(html, /control channel/);
  assert.doesNotMatch(html, /datetime-local/);
});
