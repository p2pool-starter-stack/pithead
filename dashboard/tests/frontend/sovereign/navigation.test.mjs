import assert from "node:assert/strict";
import { test } from "node:test";
import { createNavigation, readRoute, routeUrl } from "../../../mining_dashboard/web/static/sovereign/navigation.mjs";

test("legacy destinations keep expert views, chart windows and selected tabs", () => {
  const old = new URL("https://example.test/ui-preview?view=config&range=week&from=100&to=200&tab=wallets");
  const route = readRoute(old);
  assert.deepEqual(route, { page: "settings", advanced: "configuration-json" });
  const next = routeUrl(old, route.page, route.advanced);
  for (const key of ["range", "from", "to", "tab"]) assert.equal(next.searchParams.get(key), old.searchParams.get(key));
  assert.equal(next.searchParams.has("view"), false);
  assert.deepEqual(readRoute(new URL("https://example.test/?view=backup")), { page: "settings", advanced: "backup" });
  assert.equal(readRoute(new URL("https://example.test/"), "advanced").advanced, "inspect");
  assert.equal(readRoute(new URL("https://example.test/?page=constructor&advanced=__proto__")).page, "overview");
});

test("navigation, back/forward and reload guard unsaved drafts without duplicate history", () => {
  const handlers = new Map();
  const changes = [];
  const entries = [{ url: "https://example.test/ui-preview?range=week", state: null }];
  let position = 0;
  let allow = false;
  const win = {
    location: { href: entries[0].url },
    confirm: () => allow,
    history: {
      state: null,
      replaceState(state, _title, url) {
        entries[position] = { url: String(url), state };
        win.history.state = state;
        win.location.href = String(url);
      },
      pushState(state, _title, url) {
        entries.splice(position + 1);
        entries.push({ url: String(url), state });
        position++;
        win.history.state = state;
        win.location.href = String(url);
      },
      go(delta) {
        position += delta;
        win.location.href = entries[position].url;
        win.history.state = entries[position].state;
        handlers.get("popstate")({ state: entries[position].state });
      },
    },
    addEventListener: (name, fn) => handlers.set(name, fn),
    removeEventListener: (name) => handlers.delete(name),
  };
  const navigation = createNavigation({ win, dirty: () => true, onChange: (next) => changes.push(next) });
  assert.equal(navigation.go("machines"), false);
  assert.equal(changes.length, 0);
  allow = true;
  navigation.go("settings", "appearance");
  navigation.go("machines");
  allow = false;
  for (let attempt = 0; attempt < 2; attempt++) {
    win.history.go(-1);
    assert.equal(entries.length, 3);
    assert.equal(position, 2);
    assert.equal(new URL(win.location.href).searchParams.get("page"), "machines");
  }
  allow = true;
  win.history.go(-1);
  assert.equal(changes.at(-1).page, "settings");
  assert.equal(changes.at(-1).advanced, "appearance");
  win.history.go(1);
  assert.equal(changes.at(-1).page, "machines");
  let prevented = false;
  const event = { preventDefault: () => { prevented = true; } };
  handlers.get("beforeunload")(event);
  assert.ok(prevented);
  assert.equal(event.returnValue, "");
  navigation.close();
  assert.equal(handlers.size, 0);
});

test("chart query updates remain in navigation history and keep deep-link targets", () => {
  const win = { location: { href: "https://example.test/ui-preview?page=overview&range=1w&tab=kept" },
    history: { state: null, replaceState(_state, _title, url) { win.location.href = String(url); }, pushState(_state, _title, url) { win.location.href = String(url); } },
    addEventListener() {}, removeEventListener() {}, confirm: () => true };
  const navigation = createNavigation({ win, onChange() {} });
  navigation.query({ from: 100, to: 200 });
  navigation.go("machines", "pool-and-rigs", { worker: "rig-alpha" });
  let query = new URL(win.location.href).searchParams;
  assert.equal(query.get("worker"), "rig-alpha");
  assert.equal(query.get("range"), "1w");
  assert.equal(query.get("from"), "100");
  assert.equal(query.get("tab"), "kept");
  navigation.query({ range: "24h", from: null, to: null });
  navigation.go("overview");
  query = new URL(win.location.href).searchParams;
  assert.equal(query.has("from"), false);
  assert.equal(query.get("range"), "24h");
  navigation.close();
});
