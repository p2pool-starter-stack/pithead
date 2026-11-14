const BASE = "http://pithead.invalid";

export function safeNext(search) {
  const next = new URLSearchParams(search).get("next") || "/";
  try {
    const url = new URL(next, BASE);
    return url.origin === BASE ? url.pathname + url.search + url.hash : "/";
  } catch {
    return "/";
  }
}
