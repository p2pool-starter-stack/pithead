import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { X509Certificate } from "node:crypto";
import { mkdir, readFile } from "node:fs/promises";
import { isIP } from "node:net";
import { createInterface } from "node:readline";
import tls from "node:tls";
import { chromium } from "playwright";

const input = createInterface({ input: process.stdin })[Symbol.asyncIterator]();
let stage = "initialization";
let browser;

async function receive() {
  const timer = setTimeout(() => process.exit(2), 240000);
  try {
    const line = await input.next();
    assert.equal(line.done, false, "controller disconnected");
    return JSON.parse(line.value);
  } finally {
    clearTimeout(timer);
  }
}

async function exchange(event) {
  stage = event;
  console.log(JSON.stringify({ event }));
  assert.deepEqual(await receive(), { continue: true });
}

async function launch(home) {
  await mkdir(home, { recursive: true });
  return chromium.launch({
    channel: "chromium",
    args: ["--no-sandbox"],
    env: { ...process.env, HOME: home },
  });
}

async function certificate(origin) {
  const url = new URL(origin);
  const host = url.hostname.replace(/^\[|\]$/g, "");
  return new Promise((resolve, reject) => {
    // This observes identity only; Chromium below supplies the trust verdict.
    const socket = tls.connect({
      host,
      port: Number(url.port || 443),
      servername: isIP(host) ? undefined : host,
      rejectUnauthorized: false,
    });
    socket.setTimeout(10000, () => socket.destroy(new Error("TLS probe timed out")));
    socket.once("error", reject);
    socket.once("secureConnect", () => {
      const fingerprint = new X509Certificate(socket.getPeerCertificate().raw).fingerprint256;
      socket.end();
      resolve(fingerprint);
    });
  });
}

async function dashboard(response, page) {
  assert.equal(response.status(), 200, "dashboard did not respond successfully");
  assert.match(await page.title(), /pithead/i, "dashboard page was not served");
}

try {
  if (process.argv.includes("--smoke")) {
    browser = await launch("/tmp/pithead-browser-smoke");
    console.log(`Chromium ${browser.version()}`);
  } else {
    const { origin, auth } = await receive();
    const before = await certificate(origin);
    browser = await launch("/tmp/pithead-leaf-trust");
    let context = await browser.newContext({ httpCredentials: auth });
    context.setDefaultTimeout(15000);
    let page = await context.newPage();
    stage = "initial certificate warning";
    await assert.rejects(page.goto(origin), /ERR_CERT_AUTHORITY_INVALID/);
    await page.locator("#details-button").click();
    await page.locator("#proceed-link").click();
    await page.waitForLoadState("domcontentloaded");
    assert.match(await page.title(), /pithead/i);
    await exchange("leaf-accepted");
    await exchange("rotate-leaf-only");
    assert.notEqual(await certificate(origin), before, "leaf did not change");
    stage = "warning after leaf-only acceptance";
    await assert.rejects(page.reload(), /ERR_CERT_AUTHORITY_INVALID/);
    await exchange("leaf-only-red");
    await browser.close();
    browser = undefined;

    const home = "/tmp/pithead-root-trust";
    const database = `${home}/.pki/nssdb`;
    await mkdir(database, { recursive: true });
    assert.equal(new X509Certificate(await readFile("/root.crt")).ca, true);
    execFileSync("certutil", ["-N", "--empty-password", "-d", `sql:${database}`]);
    execFileSync("certutil", [
      "-A",
      "-d",
      `sql:${database}`,
      "-n",
      "Pithead test CA",
      "-t",
      "C,,",
      "-i",
      "/root.crt",
    ]);
    browser = await launch(home);
    context = await browser.newContext({ httpCredentials: auth });
    context.setDefaultTimeout(15000);
    page = await context.newPage();
    stage = "root trust before rotation";
    await dashboard(await page.goto(origin), page);
    const trustedLeaf = await certificate(origin);
    await exchange("root-trusted");
    await exchange("rotate-root-trusted");
    assert.notEqual(await certificate(origin), trustedLeaf, "trusted leaf did not change");
    stage = "root trust after rotation";
    await dashboard(await page.reload(), page);
    const fresh = await context.newPage();
    await dashboard(await fresh.goto(origin), fresh);
    await exchange("root-trust-green");
  }
} catch (error) {
  console.error(`dashboard-ca browser failed at ${stage} (${error.name})`);
  process.exitCode = 1;
} finally {
  await browser?.close();
  await input.return?.();
  process.stdin.destroy();
}
