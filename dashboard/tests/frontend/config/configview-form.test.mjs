import { test } from "node:test";
import assert from "node:assert/strict";
import { ConfigView } from "../../../mining_dashboard/web/static/config/configview.mjs";
import { renderToString } from "../helpers/render.mjs";
import { buildSections } from "../../../mining_dashboard/web/static/config/configlogic.mjs";

function stubSetState(inst) {
  inst.setState = (patch) => {
    const next = typeof patch === "function" ? patch(inst.state, inst.props) : patch;
    Object.assign(inst.state, next);
  };
}

const CFG = {
  monero: { wallet_address: "4AAAA", mode: "local", prune: true },
  p2pool: { pool: "mini", stratum_password: "" },
  dashboard: { auth: { username: "admin", password: { __secret__: true } } },
};

const CORE_KEYS = ["monero.wallet_address", "p2pool.pool", "dashboard.auth.username"];

function readyView(cfg = CFG, coreKeys = CORE_KEYS) {
  const inst = new ConfigView({});
  stubSetState(inst);
  const candidate = JSON.parse(
    JSON.stringify(Object.fromEntries(Object.entries(cfg).filter(([k]) => !k.startsWith("_")))),
  );
  const text = JSON.stringify(candidate, null, 2);
  inst.state = {
    ...inst.state,
    phase: "form",
    cfg,
    sections: buildSections(cfg),
    coreKeys,
    candidate,
    pristine: text,
    editText: text,
  };
  return inst;
}

test("load() sources the core group from the fetched config's _core_keys (config.core-keys.json, #502/#529)", async () => {
  const inst = new ConfigView({});
  stubSetState(inst);
  const withCore = { ...CFG, _core_keys: CORE_KEYS };
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    status: 200,
    ok: true,
    json: async () => withCore,
  });
  try {
    await inst.load();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.deepEqual(inst.state.coreKeys, CORE_KEYS);
  const out = renderToString(inst.render());
  assert.match(out, /Core/);
  assert.match(out, /wallet_address/);
});

test("form mode: the core section renders pinned fields; each natural section is a collapsed <details>", () => {
  const out = renderToString(readyView().render());
  assert.match(out, /config-section-core/); // the pinned core card
  assert.match(out, /<details/); // natural sections are native <details>
  assert.doesNotMatch(out, /<details[^>]*\bopen\b/); // collapsed by default, not `open`
});

test("form mode: a core key is lifted out of its own section (no duplicate row)", () => {
  const inst = readyView();
  const out = renderToString(inst.render());
  // dashboard.auth.username is core (rendered with its FULL key, since the pinned card mixes
  // several sections); dashboard.auth.password stays behind in the dashboard <details> (rendered
  // with its short relative label, since the section heading already says "dashboard").
  const matches = out.match(/config-field-name">[^<]*username/g) || [];
  assert.equal(matches.length, 1); // rendered once (in Core), not twice
  assert.match(out, /config-field-name">dashboard\.auth\.username/); // full key inside Core
  assert.match(out, /config-field-name">auth\.password/); // relative label inside its section
});

test("form mode: a section mixing top-level keys renders full labels — no two rows both named view_key (#611)", () => {
  // Wallets & payout pulls from monero.* AND tari.*; with relative labels both view_keys
  // rendered as a bare "view_key". Mixed sections must use the full dotted key.
  const cfg = {
    monero: { view_key: "", payout_scan_height: "auto" },
    tari: { view_key: "", spend_public_key: "" },
  };
  const inst = readyView(cfg, []);
  const out = renderToString(inst.render());
  assert.match(out, /config-field-name">monero\.view_key/);
  assert.match(out, /config-field-name">tari\.view_key/);
  assert.doesNotMatch(out, /config-field-name">view_key</); // no ambiguous bare label
});

test("form mode: a section mixing top-level keys only via subgroups keeps short labels on its flat fields", () => {
  // Notifications spans telegram + notifications + healthchecks, but the latter two live in their
  // own labelled subgroup <details> — the flat telegram.* remainder is single-key, so the mixed
  // check runs AFTER nestSection and the flat rows keep their relative labels.
  const cfg = {
    telegram: { enabled: false, bot_token: "" },
    healthchecks: { ping_url: "" },
  };
  const out = renderToString(readyView(cfg, []).render());
  assert.match(out, /config-field-name">enabled/); // relative, not telegram.enabled
  assert.doesNotMatch(out, /config-field-name">telegram\./);
});

test("one surface: the form AND the JSON pane render together, pane collapsed (#785)", () => {
  const out = renderToString(readyView().render());
  assert.match(out, /config-section-core/); // the form
  assert.match(out, /worker-edit/); // the pane's textarea, same class as Worker Inspect
  assert.match(out, /the configuration this page sends/); // #1850 retitled the pane
  assert.doesNotMatch(out, /<details[^>]*\bopen\b/); // pane and sections all start collapsed
});

// --- Host-only fields render greyed, not edit-then-reject (#613) -----------------------------

test("form mode: a field NOT in the editable set renders disabled with the host-only tooltip", () => {
  const inst = readyView();
  inst.state.editableKeys = ["p2pool.pool"]; // dashboard.auth.password deliberately absent
  const out = renderToString(inst.render());
  assert.match(out, /disabled/);
  assert.match(out, /Host-only — edit config\.json and run \.\/pithead apply/);
});

test("form mode: a field IN the editable set renders enabled, no host-only tooltip on it", () => {
  const inst = readyView();
  inst.state.editableKeys = ["p2pool.pool"];
  const out = renderToString(inst.render());
  // p2pool.pool is core (lifted to the pinned card) and editable — its own <label> must not carry
  // the disabled attribute or the host-only title, even though OTHER fields on the page do.
  const poolField = out.match(/<label[^>]*>\s*<span class="config-field-name">p2pool\.pool<\/span>.*?<\/label>/s);
  assert.ok(poolField, "expected to find the p2pool.pool field");
  assert.doesNotMatch(poolField[0], /disabled/);
});

test("form mode: a confirm-gated field renders enabled with the confirm-to-proceed tooltip, not host-only (#719)", () => {
  const inst = readyView();
  inst.state.editableKeys = []; // nothing freely editable
  inst.state.confirmKeys = ["monero.prune"]; // ...but prune is confirm-gated
  const out = renderToString(inst.render());
  const pruneField = out.match(/<label[^>]*>\s*<span class="config-field-name">[^<]*prune<\/span>.*?<\/label>/s);
  assert.ok(pruneField, "expected to find the monero.prune field");
  assert.doesNotMatch(pruneField[0], /disabled/); // editable, not greyed
  assert.doesNotMatch(pruneField[0], /Host-only/); // not the host-only tooltip
  assert.match(pruneField[0], /you'll type APPLY to confirm/); // the confirm affordance
});

test("form mode: an empty editable set (host not yet reporting _editable_keys) greys out every field", () => {
  const inst = readyView();
  inst.state.editableKeys = [];
  const out = renderToString(inst.render());
  // Every field input/select carries disabled — scoped to the field's own opening tag so the
  // unrelated Save/Discard buttons (also legitimately `disabled` when there's nothing to save)
  // don't inflate the count.
  // The JSON pane's own controls (textarea, file input) are gated by busy, not editability —
  // pane edits were always allowed even for host-only keys, exactly like the old JSON mode.
  const fieldTags = (out.match(/<(?:input|select)[^>]*>/g) || []).filter(
    (t) => !/type="file"/.test(t),
  );
  assert.ok(fieldTags.length > 0);
  assert.ok(fieldTags.every((t) => /disabled/.test(t)));
});

// --- Nested sub-groups within a logical section (#612) ----------------------------------------

test("form mode: telegram.events nests into its own collapsed <details>, inside the Notifications section", () => {
  const cfg = {
    ...CFG,
    telegram: { enabled: true, events: { node_down: true, worker_offline: false } },
  };
  const inst = readyView(cfg);
  const out = renderToString(inst.render());
  assert.match(out, /Telegram events \(2\)/); // the nested subgroup summary, count included
  // Nested <details> is ALSO collapsed by default — no `open` anywhere in the whole form.
  assert.doesNotMatch(out, /<details[^>]*\bopen\b/);
  assert.match(out, /config-subsection/);
});

// --- buildProposed(): both modes build the same staged config object -------------------------

test("a field edit lands in the candidate, typed, and rewrites the pane (#785)", () => {
  const inst = readyView();
  const pool = { key: "p2pool.pool", type: "select", value: "mini" };
  inst.onFieldEdit(pool, "main");
  const staged = inst.buildProposed();
  assert.equal(staged.config.p2pool.pool, "main");
  assert.equal(staged.config.monero.wallet_address, "4AAAA"); // untouched fields survive
  assert.match(inst.state.editText, /"pool": "main"/); // the pane shows the same truth
});

test("a numeric field edit stays a number in the pane, never a quoted string", () => {
  const inst = readyView();
  inst.onFieldEdit({ key: "p2pool.stratum_port", type: "number", value: 3333 }, "3334");
  assert.equal(inst.buildProposed().config.p2pool.stratum_port, 3334);
  assert.match(inst.state.editText, /"stratum_port": 3334/);
});

test("a pane edit replaces the candidate and the fields read it back (#785)", () => {
  const inst = readyView();
  const next = JSON.parse(inst.state.editText);
  next.p2pool.pool = "nano";
  inst.onJsonInput(JSON.stringify(next));
  assert.equal(inst.buildProposed().config.p2pool.pool, "nano");
  assert.match(renderToString(inst.render()), /nano/); // the form shows the pane's edit
});

test("a pane mid-typo keeps the last good candidate and blocks Save with the reason", () => {
  const inst = readyView();
  inst.onJsonInput("{not json");
  assert.match(inst.buildProposed().error, /Not valid JSON/);
  assert.equal(inst.state.editText, "{not json"); // the broken text stays visible for fixing
});

// --- Masked-secret sentinel semantics survive the candidate model (#508/#440) -----------------

test("an untouched masked secret keeps its sentinel in the staged config", () => {
  const inst = readyView();
  assert.match(inst.state.editText, /__secret__/); // visible in the pane, as a marker
  assert.deepEqual(inst.buildProposed().config.dashboard.auth.password, { __secret__: true });
});

test("blanking a secret field means KEEP — the sentinel returns, never an empty string", () => {
  const inst = readyView();
  const pw = { key: "dashboard.auth.password", type: "secret", value: "" };
  inst.onFieldEdit(pw, "hunter2hunter2");
  assert.equal(inst.buildProposed().config.dashboard.auth.password, "hunter2hunter2");
  inst.onFieldEdit(pw, "");
  assert.deepEqual(inst.buildProposed().config.dashboard.auth.password, { __secret__: true });
});

// --- File-fill button (#529, mirrors #518's ~5 lines) ------------------------------------------

test("the fill button reads a picked file into the JSON textarea via FileReader", () => {
  const inst = readyView();
  inst.state.mode = "json";
  const content = JSON.stringify({ ...CFG, p2pool: { pool: "main", stratum_password: "" } });
  let capturedOnLoad;
  class FakeFileReader {
    set onload(fn) {
      capturedOnLoad = fn;
    }
    readAsText() {
      this.result = content;
      capturedOnLoad();
    }
  }
  const realFileReader = globalThis.FileReader;
  globalThis.FileReader = FakeFileReader;
  try {
    inst.onFilePick({ target: { files: [{ name: "config.json" }] } });
  } finally {
    globalThis.FileReader = realFileReader;
  }
  assert.equal(inst.state.editText, content);
  assert.equal(inst.state.jsonError, null);
  assert.equal(inst.buildProposed().config.p2pool.pool, "main");
});

test("the fill button is a no-op when the file picker is dismissed with no file", () => {
  const inst = readyView();
  inst.state.mode = "json";
  const before = inst.state.editText;
  inst.onFilePick({ target: { files: [] } });
  assert.equal(inst.state.editText, before);
});
