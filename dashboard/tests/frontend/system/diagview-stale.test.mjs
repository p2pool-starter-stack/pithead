import assert from "node:assert/strict";
import { test } from "node:test";

import { runDiag } from "../../../mining_dashboard/web/static/system/diagview.mjs";
import { installStaleProbe, reply, STALE, withFetch } from "../helpers/stalepage.mjs";

const diagShown = async (fn) => {
  try {
    await fn();
  } catch (e) {
    return String((e && e.message) || e);
  }
  assert.fail("expected a rejection");
};

for (const [name, stub, text, reloads] of [
  ["401 with body text", async () => reply(401, "login required"), STALE, 1],
  ["403", async () => reply(403), STALE, 1],
  ["a network rejection", async () => Promise.reject(new TypeError("Failed to fetch")), STALE, 1],
  [
    "a plain-text 500",
    async () => reply(500, "control spool is full"),
    "Could not submit tor's recent log: control spool is full",
    0,
  ],
  ["an empty 500", async () => reply(500), "Could not submit tor's recent log: HTTP 500", 0],
]) {
  test(`runDiag: ${name} shows ${JSON.stringify(text)}`, async () => {
    const probe = installStaleProbe();
    const out = await withFetch(stub, () =>
      diagShown(() => runDiag("diag-logs", { container: "tor" }, "tor's recent log")),
    );
    await probe.settle();
    assert.equal(out, text);
    assert.equal(probe.reloads.length, reloads);
  });
}

test("runDiag: a 401 while reading the result shows the stale-page message and reloads", async () => {
  const probe = installStaleProbe();
  const out = await withFetch(
    async (url) =>
      url === "/api/control/diag-logs" ? reply(202, "", { id: "r-1" }) : reply(401, "login required"),
    () => diagShown(() => runDiag("diag-logs", { container: "tor" }, "tor's recent log")),
  );
  await probe.settle();
  assert.equal(out, STALE);
  assert.equal(probe.reloads.length, 1);
});
