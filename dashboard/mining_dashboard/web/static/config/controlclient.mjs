import { reportPageStale, STALE_MESSAGE } from "../app/freshness.mjs";

export class ControlError extends Error {
  toString() {
    return this.message;
  }
}

export function staleError() {
  reportPageStale();
  return new ControlError(STALE_MESSAGE);
}

export async function controlFetch(url, opts) {
  try {
    return await fetch(url, opts);
  } catch {
    throw staleError();
  }
}

export async function controlCommitResult(response, id, poll) {
  const text = await response.text();
  let result;
  if (text) {
    try {
      result = JSON.parse(text);
    } catch {
      throw new ControlError(text);
    }
  } else {
    result = await poll(id, "previewed");
  }
  if (!result || typeof result.status !== "string") throw new Error("Unreadable control response");
  if (result.status === "pending" || result.status === "previewed") return poll(id, "previewed");
  return result;
}

export async function requirePreviewResponse(response) {
  if (response.status === 401 || response.status === 403) throw staleError();
  if (!response.ok && response.status !== 202) {
    throw new ControlError((await response.text()) || `HTTP ${response.status}`);
  }
}
