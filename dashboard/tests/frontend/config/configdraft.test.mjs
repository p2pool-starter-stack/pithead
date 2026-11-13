import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import {
  DRAFT_KEY,
  draftNote,
  redactDraft,
  restoreDraft,
  SECRET_PATHS,
  syncDraft,
} from "../../../mining_dashboard/web/static/config/configdraft.mjs";
import { ConfigView } from "../../../mining_dashboard/web/static/config/configview.mjs";
import { renderToString } from "../helpers/render.mjs";
import { reply, withFetch } from "../helpers/stalepage.mjs";

const memory = (seed = {}) => {
  const data = { ...seed };
  return {
    data,
    getItem: (k) => (k in data ? data[k] : null),
    setItem: (k, v) => {
      data[k] = String(v);
    },
    removeItem: (k) => {
      delete data[k];
    },
  };
};

const CFG = {
  dashboard: { auth: { password: { __secret__: true } }, energy: { cost_per_kwh: 0.1 } },
  _editable_keys: ["dashboard.energy.cost_per_kwh", "dashboard.auth.password"],
};
const state = (over) => ({
  candidate: {},
  cfg: CFG,
  pristine: '{"a":1}',
  editText: '{"a":1}',
  drafts: {},
  ...over,
});

test("syncDraft stores only a draft that differs from pristine and removes it when they match", () => {
  const store = memory();
  syncDraft(state(), store);
  assert.equal(DRAFT_KEY in store.data, false);
  syncDraft(state({ editText: '{"a":2}', drafts: { "x.y": "1." } }), store);
  const stored = JSON.parse(store.data[DRAFT_KEY]);
  assert.deepEqual(JSON.parse(stored.editText), { a: 2 });
  assert.deepEqual(stored.drafts, { "x.y": "1." });
  syncDraft(state(), store);
  assert.equal(DRAFT_KEY in store.data, false);
});

test("syncDraft leaves the stash alone before a config has loaded", () => {
  const store = memory({ [DRAFT_KEY]: "kept" });
  syncDraft({ candidate: null, cfg: null, pristine: "", editText: "", drafts: {} }, store);
  assert.equal(store.data[DRAFT_KEY], "kept");
});

test("syncDraft survives unavailable storage", () => {
  const broken = {
    setItem: () => {
      throw new Error("quota");
    },
    removeItem: () => {
      throw new Error("quota");
    },
  };
  syncDraft(state({ editText: "x" }), broken);
  syncDraft(state(), broken);
});

test("a typed secret never reaches storage; the sentinel is stored in its place", () => {
  const plain = ["typed", "later"].join("-");
  const typed = JSON.stringify({ dashboard: { auth: { password: plain }, energy: {} } });
  const store = memory();
  syncDraft(state({ editText: typed }), store);
  const raw = store.data[DRAFT_KEY];
  assert.equal(raw.includes(plain), false);
  assert.deepEqual(JSON.parse(JSON.parse(raw).editText).dashboard.auth.password, { __secret__: true });
});

const LEAKS = [
  ["a typed worker token", '{"workers":{"list":[{"token":"LEAK"}]}}'],
  ["a typed worker api_token", '{"workers":{"list":[{"api_token":"LEAK"}]}}'],
  ["a typed webhook", '{"notifications":{"webhooks":["https://hook.example/LEAK"]}}'],
  ["a typed value for an unset secret", '{"monero":{"node_password":"LEAK"}}'],
  ["a typed ntfy token", '{"notifications":{"ntfy":{"token":"LEAK"}}}'],
  ["a typed view key", '{"tari":{"view_key":"LEAK"}}'],
  ["a duplicate key", '{"telegram":{"bot_token":"LEAK"},"telegram":{}}'],
  ["a sentinel with extra properties", '{"telegram":{"bot_token":{"__secret__":true,"v":"LEAK"}}}'],
  ["a webhook sentinel with a text slot", '{"notifications":{"webhooks":[{"__secret__":true,"slot":"LEAK"}]}}'],
  ["a typed object where a secret goes", '{"telegram":{"bot_token":{"x":"LEAK"}}}'],
];
for (const [name, text] of LEAKS) {
  test(`redactDraft never keeps ${name}`, () => {
    assert.doesNotMatch(redactDraft(text, CFG), /LEAK/);
  });
}

test("redactDraft resets a typed secret to what the server sent: its marker, or empty when unset", () => {
  const cfg = { dashboard: { auth: { password: { __secret__: true } } } };
  const out = JSON.parse(
    redactDraft('{"dashboard":{"auth":{"password":"new"}},"monero":{"node_password":"typed"}}', cfg),
  );
  assert.deepEqual(out.dashboard.auth.password, { __secret__: true });
  assert.equal(out.monero.node_password, "");
});

test("redactDraft leaves same-named non-secret keys alone", () => {
  const text = '{"xvb":{"url":"na.example:4247"},"monero":{"source":"x"},"label":"password"}';
  assert.deepEqual(JSON.parse(redactDraft(text, CFG)), JSON.parse(text));
});

test("an invalid-JSON draft stores the last valid candidate, never the broken text", () => {
  const store = memory();
  const broken = '{"monero": {"node_password": "LEAK';
  syncDraft(
    state({ candidate: { a: 2 }, editText: broken, jsonError: "Unexpected end of JSON input" }),
    store,
  );
  const raw = store.data[DRAFT_KEY];
  assert.doesNotMatch(raw, /LEAK/);
  assert.deepEqual(JSON.parse(JSON.parse(raw).editText), { a: 2 });
});

test("an invalid numeric field draft alone is kept and restored without a marker", () => {
  const store = memory();
  syncDraft(state({ drafts: { "dashboard.energy.cost_per_kwh": "-" } }), store);
  assert.ok(DRAFT_KEY in store.data);
  const out = restoreDraft(JSON.stringify({ a: 1 }, null, 2), store);
  assert.deepEqual(out, { drafts: { "dashboard.energy.cost_per_kwh": "-" }, draftRestored: true });
});

test("a valid numeric field draft alone is not a draft", () => {
  const store = memory({ [DRAFT_KEY]: "old" });
  syncDraft(state({ drafts: { "dashboard.energy.cost_per_kwh": "0.3" } }), store);
  assert.equal(DRAFT_KEY in store.data, false);
});

test("a draft too large to store is dropped", () => {
  const store = memory({ [DRAFT_KEY]: "old" });
  syncDraft(state({ editText: "x".repeat(600000) }), store);
  assert.equal(DRAFT_KEY in store.data, false);
});

test("the client's secret paths match the server's SECRET_PATHS", () => {
  const source = readFileSync(
    new URL("../../../mining_dashboard/service/control_service.py", import.meta.url),
    "utf8",
  );
  const block = source.match(/^SECRET_PATHS = \[([\s\S]*?)^\]/m)[1];
  const server = [...block.matchAll(/^\s*\(([^)]*)\),/gm)].map(([, tuple]) =>
    [...tuple.matchAll(/"([^"]+)"/g)].map(([, key]) => key),
  );
  assert.ok(server.length > 5);
  assert.deepEqual(SECRET_PATHS, server);
});

test("redactDraft keeps the document when no secret was typed", () => {
  const text = '{ "dashboard": {"auth": {"password": {"__secret__": true}}} }';
  assert.deepEqual(JSON.parse(redactDraft(text, CFG)), JSON.parse(text));
});

test("restoreDraft returns the draft with its text, drafts and a restored flag", () => {
  const stash = { editText: '{"a":2}', drafts: { "x.y": "1." } };
  const store = memory({ [DRAFT_KEY]: JSON.stringify(stash) });
  const out = restoreDraft('{"a":1}', store);
  assert.equal(out.draftRestored, true);
  assert.equal(out.jsonError, null);
  assert.deepEqual(out.drafts, { "x.y": "1." });
  assert.deepEqual(out.candidate, { a: 2 });
  assert.equal(out.editText, '{"a":2}');
});

test("restoreDraft keeps an invalid-JSON draft with its error", () => {
  const store = memory({ [DRAFT_KEY]: JSON.stringify({ editText: '{"a": ', drafts: {} }) });
  const out = restoreDraft('{"a":1}', store);
  assert.equal(out.editText, '{"a": ');
  assert.ok(out.jsonError);
  assert.equal(out.draftRestored, true);
  assert.equal("candidate" in out, false);
});

test("restoreDraft drops garbage and a draft identical to the fetched config", () => {
  for (const raw of [null, "not json", "[]", '"s"', '{"editText":5}', '{"editText":"{\\"a\\":1}"}']) {
    const store = memory(raw === null ? {} : { [DRAFT_KEY]: raw });
    assert.equal(restoreDraft('{"a":1}', store), null, String(raw));
  }
});

test("restoreDraft keeps only string field drafts", () => {
  const store = memory({
    [DRAFT_KEY]: JSON.stringify({ editText: '{"a":2}', drafts: { ok: "1.", bad: 5, worse: null } }),
  });
  assert.deepEqual(restoreDraft('{"a":1}', store).drafts, { ok: "1." });
});

test("draftNote renders one status line only for a restored draft", () => {
  assert.equal(draftNote({ draftRestored: false }), null);
  assert.match(renderToString(draftNote({ draftRestored: true })), /unsaved edits were restored/);
});

const FETCHED = { dashboard: { energy: { cost_per_kwh: 0.1 } }, _editable_keys: ["dashboard.energy.cost_per_kwh"] };

async function mounted(seed) {
  const real = globalThis.sessionStorage;
  const store = memory(seed);
  globalThis.sessionStorage = store;
  const view = new ConfigView({});
  view.setState = (patch) => Object.assign(view.state, patch);
  await withFetch(async () => reply(200, "", FETCHED), () => view.load(true));
  return { view, store, restore: () => (globalThis.sessionStorage = real) };
}

test("ConfigView restores a stashed draft on load and flags it", async () => {
  const draft = JSON.stringify({ dashboard: { energy: { cost_per_kwh: 0.25 } } }, null, 2);
  const { view, restore } = await mounted({ [DRAFT_KEY]: JSON.stringify({ editText: draft, drafts: {} }) });
  restore();
  assert.equal(view.state.editText, draft);
  assert.notEqual(view.state.editText, view.state.pristine);
  assert.equal(view.state.candidate.dashboard.energy.cost_per_kwh, 0.25);
  assert.equal(view.state.draftRestored, true);
});

test("ConfigView ignores the stash when load is not a restore (Discard edits)", async () => {
  const draft = JSON.stringify({ dashboard: { energy: { cost_per_kwh: 0.25 } } }, null, 2);
  const { view, store, restore } = await mounted({ [DRAFT_KEY]: JSON.stringify({ editText: draft, drafts: {} }) });
  await withFetch(async () => reply(200, "", FETCHED), () => view.load());
  view.componentDidUpdate({}, { editText: "", pristine: "" });
  restore();
  assert.equal(view.state.editText, view.state.pristine);
  assert.equal(view.state.draftRestored, false);
  assert.equal(DRAFT_KEY in store.data, false);
});

test("ConfigView persists an edit and clears the stash once the save is applied", async () => {
  const { view, store, restore } = await mounted({});
  const field = view.state.sections
    .flatMap((s) => s.fields)
    .find(({ key }) => key === "dashboard.energy.cost_per_kwh");
  view.onFieldEdit(field, "0.3");
  view.componentDidUpdate({}, { editText: view.state.pristine, pristine: view.state.pristine });
  assert.match(JSON.parse(store.data[DRAFT_KEY]).editText, /0\.3/);
  view.state.pristine = view.state.editText;
  view.componentDidUpdate({}, { editText: view.state.editText, pristine: "" });
  restore();
  assert.equal(DRAFT_KEY in store.data, false);
});
