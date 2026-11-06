#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, X509Certificate } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";

const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function identityFromPem(pem) {
  const cert = new X509Certificate(pem);
  return {
    fingerprint: createHash("sha256").update(cert.raw).digest("hex"),
    key: createHash("sha256")
      .update(cert.publicKey.export({ type: "spki", format: "der" }))
      .digest("hex"),
    sans: (cert.subjectAltName || "")
      .split(/,\s*/)
      .filter(Boolean)
      .map((value) => value.trim().toLowerCase())
      .sort(),
  };
}

function assertContinuity(before, after) {
  assert.deepEqual(after.sans, before.sans);
  assert.equal(after.fingerprint, before.fingerprint);
  assert.equal(after.key, before.key);
}

async function waitForFile(path, attempts, interval) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (existsSync(path)) return;
    await pause(interval);
  }
  assert.fail(`timed out waiting for ${path}`);
}

function makeCertificate(directory, name, sans) {
  const key = join(directory, `${name}.key`);
  const cert = join(directory, `${name}.crt`);
  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-subj",
      `/CN=${name}`,
      "-addext",
      `subjectAltName=${sans}`,
      "-keyout",
      key,
      "-out",
      cert,
      "-days",
      "1",
    ],
    { stdio: "ignore" },
  );
  return identityFromPem(readFileSync(cert));
}

async function selfTest() {
  const directory = mkdtempSync(join(tmpdir(), "pithead-browser-selftest."));
  try {
    const first = makeCertificate(directory, "first", "DNS:pithead.local,IP:127.0.0.1");
    const replacement = makeCertificate(directory, "replacement", "DNS:pithead.local,IP:127.0.0.1");
    const changedSans = makeCertificate(
      directory,
      "changed",
      "DNS:pithead.local,DNS:new.local,IP:127.0.0.1",
    );
    assert.doesNotThrow(() => assertContinuity(first, first));
    assert.throws(() => assertContinuity(first, replacement));
    assert.throws(() => assertContinuity(first, changedSans));
    const marker = join(directory, "marker");
    await assert.rejects(waitForFile(marker, 1, 0), /timed out/);
    writeFileSync(marker, "ready\n");
    await waitForFile(marker, 1, 0);
    process.stdout.write("image-upgrade-browser self-test: PASS\n");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

if (process.argv[2] === "--self-test") {
  await selfTest();
  process.exit(0);
}

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const [origin] = process.argv.slice(2);
const credentials = JSON.parse(
  await new Promise((resolve, reject) => {
    let body = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => (body += chunk));
    process.stdin.on("end", () => resolve(body));
    process.stdin.on("error", reject);
  }),
);
assert.ok(origin && credentials.username && credentials.password);

function servedIdentity() {
  const target = new URL(origin);
  const pem = execFileSync(
    "openssl",
    [
      "s_client",
      "-connect",
      `${target.hostname}:${target.port || "443"}`,
      "-servername",
      target.hostname,
      "-showcerts",
    ],
    { input: "", encoding: "utf8", timeout: 15000, stdio: ["pipe", "pipe", "ignore"] },
  ).match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/)?.[0];
  assert.ok(pem);
  return identityFromPem(pem);
}

const before = servedIdentity();
process.stdout.write(
  `preboot identity fingerprint=${before.fingerprint} key=${before.key} sans=${JSON.stringify(before.sans)}\n`,
);
const browser = await chromium.launch({ channel: "chromium", headless: true });
try {
  const context = await browser.newContext({ httpCredentials: credentials });
  context.setDefaultTimeout(120000);
  const page = await context.newPage();
  await assert.rejects(page.goto(origin), /ERR_CERT_AUTHORITY_INVALID/);
  await page.locator("#details-button").click();
  await page.locator("#proceed-link").click();
  await page.getByRole("button", { name: "OS updates", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "System update" });
  await dialog.getByRole("button", { name: "Check now", exact: true }).click();
  await dialog.getByRole("button", { name: "Download", exact: true }).click({ timeout: 180000 });
  await dialog.getByRole("button", { name: "Install", exact: true }).click({ timeout: 1800000 });
  await dialog.getByRole("button", { name: "Reboot", exact: true }).click({ timeout: 1200000 });
  await dialog.getByLabel(/Type REBOOT to confirm/).fill("REBOOT");
  await dialog.getByRole("button", { name: "Reboot now", exact: true }).click();
  writeFileSync("/work/restore-request", "ready\n");
  await waitForFile("/work/restore-complete", 300, 5000);
  let after;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const candidate = servedIdentity();
      if (JSON.stringify(candidate.sans) === JSON.stringify(before.sans)) {
        after = candidate;
        break;
      }
    } catch {}
    await pause(5000);
  }
  assert.ok(after);
  assertContinuity(before, after);
  const stateResponse = await page.waitForResponse(
    (response) =>
      response.request().frame() === page.mainFrame() &&
      new URL(response.url()).pathname === "/api/state" &&
      response.ok(),
    { timeout: 1200000 },
  );
  assert.equal(stateResponse.request().frame(), page.mainFrame());
  await page.getByText(/System updated to v/).waitFor({ timeout: 1200000 });
  assert.equal(context.pages().length, 1);
  assert.equal(await page.locator("#proceed-link").count(), 0);
  process.stdout.write(
    `postupdate identity fingerprint=${after.fingerprint} key=${after.key} sans=${JSON.stringify(after.sans)} same_tab_api_state=true second_trust_decision=false\n`,
  );
} finally {
  await browser.close();
}
