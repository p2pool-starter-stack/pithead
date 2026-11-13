export function safeNext(search) {
  const next = new URLSearchParams(search).get("next") || "/";
  return next.startsWith("/") && !next.startsWith("//") && !next.includes("\\") ? next : "/";
}
