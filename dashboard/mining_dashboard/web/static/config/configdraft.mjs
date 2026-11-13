import { html } from "../app/preact.mjs";
import {
  editableCandidate,
  isSecretSentinel,
  jsonSyntaxError,
  parseConfigJson,
} from "./configlogic.mjs";

export const DRAFT_KEY = "pitheadConfigDraft";
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

export const SECRET_PATHS = [
  ["dashboard", "auth", "password"],
  ["telegram", "bot_token"],
  ["workers", "api_token"],
  ["monero", "node_username"],
  ["monero", "node_password"],
  ["monero", "view_key"],
  ["tari", "view_key"],
  ["p2pool", "stratum_password"],
  ["healthchecks", "ping_url"],
  ["notifications", "ntfy", "url"],
  ["notifications", "ntfy", "token"],
  ["xvb", "standby", "source"],
];
const WORKER_TOKENS = ["token", "api_token"];
const SENTINEL_TEXT = '{"__secret__": true}';
const TOKEN = /"(?:[^"\\\n]|\\.)*(?:"|$)|[{}[\]:,]|[^\s{}[\]:,"]+/gm;
const isWord = (t) => !/^[{}[\]:,]$/.test(t);
const decode = (t) => {
  try {
    return JSON.parse(t);
  } catch {
    return t.replace(/^"/, "").replace(/"$/, "");
  }
};
const secretKey = (name, parent) =>
  [...SECRET_PATHS, ["workers", "list", "token"], ["workers", "list", "api_token"]].some(
    (path) =>
      path[path.length - 1] === name &&
      (parent === undefined || parent === null || path[path.length - 2] === parent),
  );

function scrubText(text) {
  const tokens = [...text.matchAll(TOKEN)];
  const stack = [];
  const edits = [];
  let lastKey = null;
  let hooks = -1;
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i][0];
    const at = tokens[i].index;
    if (t === "{" || t === "[") {
      stack.push(lastKey);
      if (t === "[" && lastKey === "webhooks") hooks = stack.length;
    } else if (t === "}" || t === "]") {
      if (stack.length === hooks) hooks = -1;
      stack.pop();
    } else if (isWord(t)) {
      const next = tokens[i + 1]?.[0];
      if (next === ":") lastKey = decode(t);
      if (hooks === stack.length && next !== ":") {
        edits.push([at, t.length, '""']);
        continue;
      }
      if (!secretKey(decode(t), stack[stack.length - 1])) continue;
      const j = next === ":" ? i + 2 : i + 1;
      if (tokens[j] && isWord(tokens[j][0]))
        edits.push([tokens[j].index, tokens[j][0].length, SENTINEL_TEXT]);
    }
  }
  return edits.reduceRight(
    (out, [at, length, value]) => out.slice(0, at) + value + out.slice(at + length),
    text,
  );
}

const keep = (fetched) => (isSecretSentinel(fetched) ? fetched : "");
const typed = (v) => Boolean(v) && !isSecretSentinel(v);

function scrubDocument(doc, cfg) {
  let changed = false;
  const reset = (parent, key, fetchedParent) => {
    if (!parent || typeof parent !== "object" || !typed(parent[key])) return;
    parent[key] = keep(fetchedParent?.[key]);
    changed = true;
  };
  const at = (root, path) =>
    path.reduce((node, key) => (isObject(node) ? node[key] : undefined), root);
  for (const path of SECRET_PATHS)
    reset(at(doc, path.slice(0, -1)), path[path.length - 1], at(cfg, path.slice(0, -1)));
  const hooks = at(doc, ["notifications", "webhooks"]);
  const fetchedHooks = at(cfg, ["notifications", "webhooks"]);
  for (let i = 0; Array.isArray(hooks) && i < hooks.length; i++) reset(hooks, i, fetchedHooks);
  const workers = at(doc, ["workers", "list"]);
  const fetchedWorkers = at(cfg, ["workers", "list"]);
  for (let i = 0; Array.isArray(workers) && i < workers.length; i++)
    for (const key of WORKER_TOKENS) reset(workers[i], key, fetchedWorkers?.[i]);
  return changed;
}

export function redactDraft(text, cfg) {
  let doc;
  try {
    doc = JSON.parse(text);
  } catch {
    return scrubText(text);
  }
  return scrubDocument(doc, cfg) ? JSON.stringify(doc, null, 2) : text;
}

export function syncDraft({ candidate, cfg, pristine, editText, drafts }, store) {
  if (!candidate) return;
  try {
    store ??= sessionStorage;
    if (editText === pristine) store.removeItem(DRAFT_KEY);
    else store.setItem(DRAFT_KEY, JSON.stringify({ editText: redactDraft(editText, cfg), drafts }));
  } catch {
    return;
  }
}

export function restoreDraft(fetchedText, store) {
  let stash;
  try {
    store ??= sessionStorage;
    stash = JSON.parse(store.getItem(DRAFT_KEY));
  } catch {
    return null;
  }
  if (!isObject(stash) || typeof stash.editText !== "string" || stash.editText === fetchedText)
    return null;
  const drafts = Object.fromEntries(
    Object.entries(isObject(stash.drafts) ? stash.drafts : {}).filter(
      ([, raw]) => typeof raw === "string",
    ),
  );
  const error = jsonSyntaxError(stash.editText);
  const staged = error ? { error } : parseConfigJson(stash.editText);
  if (staged.error)
    return { editText: stash.editText, drafts, jsonError: staged.error, draftRestored: true };
  const candidate = editableCandidate(staged.config);
  const editText =
    JSON.stringify(candidate) === JSON.stringify(staged.config)
      ? stash.editText
      : JSON.stringify(candidate, null, 2);
  if (editText === fetchedText) return null;
  return { candidate, editText, drafts, jsonError: null, draftRestored: true };
}

export const draftNote = (state) =>
  state.draftRestored
    ? html`<p class="text-muted text-xs" role="status">Your unsaved edits were restored after the page reloaded.</p>`
    : null;
