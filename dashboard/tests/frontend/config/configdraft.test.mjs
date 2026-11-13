import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DRAFT_KEY,
  draftNote,
  redactDraft,
  restoreDraft,
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
  assert.deepEqual(JSON.parse(store.data[DRAFT_KEY]), { editText: '{"a":2}', drafts: { "x.y": "1." } });
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
  const typed = JSON.stringify({ dashboard: { auth: { password: "hunter2-plain" }, energy: {} } });
  const store = memory();
  syncDraft(state({ editText: typed }), store);
  const raw = store.data[DRAFT_KEY];
  assert.doesNotMatch(raw, /hunter2-plain/);
  assert.deepEqual(JSON.parse(JSON.parse(raw).editText).dashboard.auth.password, { __secret__: true });
});

test("a typed secret inside invalid JSON is redacted too", () => {
  const broken = '{"dashboard": {"auth": {"password": "hunter2-plain", "x": }';
  const out = redactDraft(broken, CFG);
  assert.doesNotMatch(out, /hunter2-plain/);
  assert.match(out, /"password": \{"__secret__": true\}/);
});

test("redactDraft keeps text untouched when no secret was replaced", () => {
  const text = '{ "dashboard": {"auth": {"password": {"__secret__": true}}} }';
  assert.equal(redactDraft(text, CFG), text);
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
