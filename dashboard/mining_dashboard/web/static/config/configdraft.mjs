import { html } from "../app/preact.mjs";
import { validNumber } from "./configfield.mjs";
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
const MAX_DRAFT_CHARS = 500000;

const keep = (fetched) => (plainSentinel(fetched) ? fetched : "");
const plainSentinel = (v) =>
  isSecretSentinel(v) && Object.values(v).every((x) => x === true || typeof x === "number");
const typed = (v) => Boolean(v) && !plainSentinel(v);

function scrubDocument(doc, cfg) {
  const reset = (parent, key, fetchedParent) => {
    if (!parent || typeof parent !== "object" || !typed(parent[key])) return;
    parent[key] = keep(fetchedParent?.[key]);
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
}

export function redactDraft(text, cfg) {
  const doc = JSON.parse(text);
  scrubDocument(doc, cfg);
  return JSON.stringify(doc, null, 2);
}

export function syncDraft({ candidate, cfg, pristine, editText, drafts, jsonError }, store) {
  if (!candidate) return;
  try {
    store ??= sessionStorage;
    if (
      (editText === pristine && Object.values(drafts).every(validNumber)) ||
      editText.length > MAX_DRAFT_CHARS
    ) {
      store.removeItem(DRAFT_KEY);
      return;
    }
    const text = jsonError ? JSON.stringify(candidate, null, 2) : editText;
    store.setItem(DRAFT_KEY, JSON.stringify({ editText: redactDraft(text, cfg), drafts }));
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
  if (!isObject(stash) || typeof stash.editText !== "string") return null;
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
  if (editText === fetchedText)
    return Object.keys(drafts).length ? { drafts, draftRestored: true } : null;
  return { candidate, editText, drafts, jsonError: null, draftRestored: true };
}

export const draftNote = (state) =>
  state.draftRestored
    ? html`<p class="text-muted text-xs" role="status">Your unsaved edits were restored after the page reloaded.</p>`
    : null;
