import assert from "node:assert/strict";
import { test } from "node:test";

import { initDashboard } from "../../../mining_dashboard/web/static/dashboard.js";

const ok = () => Promise.resolve({ ok: true, json: async () => ({}) });

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

test("sovereign chart navigation preserves the opt-in query and current hash route", async () => {
  const urls = [];
  const paints = [];
  const events = {};
  let current = "http://pithead.test/?ui=sovereign&fixture=empty#machines";
  const priorLocation = globalThis.location;
  globalThis.location = { hash: "#machines" };
  try {
    const dashboard = initDashboard({
      doc: {
        title: "",
        documentElement: { setAttribute() {} },
        getElementById: () => null,
      },
      storage: { getItem: () => null, setItem() {} },
      href: current,
      currentHref: () => current,
      listen: (name, fn) => { events[name] = fn; },
      fetchFn: ok,
      replaceUrl: (url) => {
        urls.push(url);
        current = new URL(url, current).href;
      },
      schedule() {},
      renderApp: (props) => paints.push(props),
    });
    await dashboard.firstLoad;
    await paints.at(-1).onRange("1h");
    await paints.at(-1).onZoom(1_000.4, 2_000.6);
    await paints.at(-1).onResetZoom();
    await paints.at(-1).onRange("all");

    assert.deepEqual(urls, [
      "/?ui=sovereign&fixture=empty&range=1h#machines",
      "/?ui=sovereign&fixture=empty&from=1000&to=2001#machines",
      "/?ui=sovereign&fixture=empty&range=1h#machines",
      "/?ui=sovereign&fixture=empty#machines",
    ]);
    current = "http://pithead.test/?ui=sovereign&range=24h#overview";
    await events.popstate();
    assert.equal(paints.at(-1).ui.range, "24h");
    assert.equal(paints.at(-1).ui.window, null);
    current = "http://pithead.test/?ui=sovereign&from=100&to=200#earnings";
    await events.popstate();
    assert.deepEqual(paints.at(-1).ui.window, { from: 100, to: 200 });
    await paints.at(-1).onRange("1w");
    assert.equal(urls.at(-1), "/?ui=sovereign&range=1w#earnings");
  } finally {
    if (priorLocation === undefined) delete globalThis.location;
    else globalThis.location = priorLocation;
  }
});

test("range changes and Back during a poll discard stale data and fetch the latest URL", async () => {
  const first = deferred();
  const fetches = [];
  const paints = [];
  const events = {};
  let current = "http://pithead.test/?ui=sovereign#overview";
  const dashboard = initDashboard({
    doc: {
      title: "",
      documentElement: { setAttribute() {} },
      getElementById: () => null,
    },
    storage: { getItem: () => null, setItem() {} },
    href: current,
    currentHref: () => current,
    listen: (name, fn) => { events[name] = fn; },
    fetchFn: (url) => {
      fetches.push(url);
      if (fetches.length === 1) return first.promise;
      return Promise.resolve({ ok: true, json: async () => ({ sample: "latest" }) });
    },
    replaceUrl: (url) => { current = new URL(url, current).href; },
    schedule() {},
    renderApp: (props) => paints.push(props),
  });

  const rangeChange = paints.at(-1).onRange("24h");
  current = "http://pithead.test/?ui=sovereign&range=1w#overview";
  const back = events.popstate();
  first.resolve({ ok: true, json: async () => ({ sample: "stale" }) });
  await Promise.all([dashboard.firstLoad, rangeChange, back]);

  assert.deepEqual(fetches, [
    "/api/state?range=all&avg=10m",
    "/api/state?range=1w&avg=10m",
  ]);
  assert.equal(paints.some(({ state }) => state?.sample === "stale"), false);
  assert.equal(paints.at(-1).state.sample, "latest");
  assert.equal(paints.at(-1).ui.range, "1w");
});

test("invalid Sovereign range parameters fall back to the supported all range", async () => {
  const fetches = [];
  const paints = [];
  const events = {};
  let current = "http://pithead.test/?ui=sovereign&range=bogus#overview";
  const dashboard = initDashboard({
    doc: {
      title: "",
      documentElement: { setAttribute() {} },
      getElementById: () => null,
    },
    storage: { getItem: () => null, setItem() {} },
    href: current,
    currentHref: () => current,
    listen: (name, fn) => { events[name] = fn; },
    fetchFn: (url) => {
      fetches.push(url);
      return ok();
    },
    replaceUrl() {},
    schedule() {},
    renderApp: (props) => paints.push(props),
  });
  await dashboard.firstLoad;
  assert.equal(paints.at(-1).ui.range, "all");
  assert.equal(fetches.at(-1), "/api/state?range=all&avg=10m");

  current = "http://pithead.test/?ui=sovereign&range=%20nope%20#overview";
  assert.equal(await events.popstate(), undefined);
  assert.equal(fetches.length, 1);
});
