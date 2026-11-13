import { html } from "../app/preact.mjs";
import {
  editableCandidate,
  isSecretSentinel,
  jsonSyntaxError,
  parseConfigJson,
} from "./configlogic.mjs";

export const DRAFT_KEY = "pitheadConfigDraft";
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function secretPaths(node, prefix = [], out = []) {
  for (const [key, value] of Object.entries(node || {})) {
    if (isSecretSentinel(value)) out.push([...prefix, key]);
    else if (isObject(value)) secretPaths(value, [...prefix, key], out);
  }
  return out;
}

export function redactDraft(text, cfg) {
  const paths = secretPaths(cfg);
  let doc;
  try {
    doc = JSON.parse(text);
  } catch {
    return paths.reduce((out, path) => {
      const leaf = path[path.length - 1].replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      return out.replace(
        new RegExp(`("${leaf}"\\s*:\\s*)"(?:[^"\\\\]|\\\\.)*"`, "g"),
        '$1{"__secret__": true}',
      );
    }, text);
  }
  let changed = false;
  for (const path of paths) {
    const parent = path
      .slice(0, -1)
      .reduce((node, key) => (isObject(node) ? node[key] : undefined), doc);
    const leaf = path[path.length - 1];
    if (isObject(parent) && leaf in parent && !isSecretSentinel(parent[leaf])) {
      parent[leaf] = { __secret__: true };
      changed = true;
    }
  }
  return changed ? JSON.stringify(doc, null, 2) : text;
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
