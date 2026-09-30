export async function controlCommitResult(response, id, poll) {
  let result = await response.text();
  result = result ? JSON.parse(result) : await poll(id, "previewed");
  if (!result || typeof result.status !== "string") throw new Error("Unreadable control response");
  if (result.status === "pending" || result.status === "previewed") return poll(id, "previewed");
  return result;
}
