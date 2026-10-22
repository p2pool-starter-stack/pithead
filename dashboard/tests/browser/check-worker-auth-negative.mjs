import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { stripVTControlCharacters } from "node:util";

assert.ok(process.env.TMPDIR, "TMPDIR is required for negative-control artifacts");
const scratch = mkdtempSync(join(process.env.TMPDIR, "worker-auth-negative-"));
const staticRoot = join(scratch, "static");
cpSync(new URL("../../mining_dashboard/web/static/", import.meta.url), staticRoot, {
  recursive: true,
});
const table = join(staticRoot, "workers/workertable.mjs");
const original = readFileSync(table, "utf8");
const guard = "if (w.api_ok !== false) return null;";
assert.equal(
  original.split(guard).length,
  2,
  "API badge guard must have exactly one mutation site",
);
writeFileSync(
  table,
  original.replace(
    guard,
    "if (w.api_ok === false) globalThis.workerAuthFailed = true; if (!globalThis.workerAuthFailed) return null;",
  ),
);
const result = spawnSync(
  process.execPath,
  [
    fileURLToPath(new URL("node_modules/@playwright/test/cli.js", import.meta.url)),
    "test",
    "workers.test.mjs",
    "--project=chromium",
    "--grep=worker API warning appears",
    "--reporter=json",
    `--output=${join(scratch, "results")}`,
  ],
  {
    cwd: fileURLToPath(new URL(".", import.meta.url)),
    env: { ...process.env, PITHEAD_BROWSER_STATIC: staticRoot },
    encoding: "utf8",
    timeout: 90000,
  },
);
writeFileSync(join(scratch, "report.json"), result.stdout || "");
writeFileSync(join(scratch, "stderr.log"), result.stderr || "");
assert.ifError(result.error);
assert.equal(result.status, 1, "a sticky API badge must fail the recovery journeys");
const report = JSON.parse(result.stdout);
assert.equal(report.stats.expected, 0);
assert.equal(report.stats.unexpected, 2);
assert.equal(report.stats.skipped, 0);
const results = report.suites.flatMap((suite) => suite.specs.flatMap((spec) => spec.tests));
assert.equal(results.length, 2);
for (const test of results) {
  const message = stripVTControlCharacters(test.results[0].error.message);
  assert.match(message, /toHaveCount/);
  assert.match(message, /Expected: 0/);
  assert.match(message, /Received: 1/);
}
console.log(
  "worker auth sticky-badge negative control: both recovery assertions failed as required",
);
