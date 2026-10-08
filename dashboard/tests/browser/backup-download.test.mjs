import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:https";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";
import { test } from "node:test";
import { chromium } from "playwright";

const staticRoot = resolve(process.env.PITHEAD_BROWSER_STATIC ||
  new URL("../../mining_dashboard/web/static/", import.meta.url).pathname);
const id = "11111111-1111-4111-8111-111111111111";
const archiveName = "pithead-backup-fixture.tar.gz.enc";
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const fixture = `<!doctype html><html><body><div id="fixture"></div>
<script type="module">
import { html, render } from '/static/app/preact.mjs';
import { BackupPanel } from '/static/system/backupview.mjs';
render(html\`<\${BackupPanel} enabled=\${true} appliance=\${true} />\`,
  document.getElementById('fixture'));
</script></body></html>`;

async function setup(t, disableExtensions) {
  const scratch = await mkdtemp(join(tmpdir(), "pithead-backup-browser-"));
  t.after(() => rm(scratch, { recursive: true, force: true }));
  const configBytes = Buffer.from('{"fixture":"backup-download"}\n');
  const databaseBytes = randomBytes(22 * 1024 * 1024);
  await writeFile(join(scratch, "config.json"), configBytes);
  await writeFile(join(scratch, "dashboard.db"), databaseBytes);
  const plain = execFileSync("tar", ["-czf", "-", "-C", scratch,
    "config.json", "dashboard.db"], { maxBuffer: 32 * 1024 * 1024 });
  const passphrase = randomBytes(24).toString("hex");
  const archive = execFileSync("openssl", ["enc", "-aes-256-cbc", "-pbkdf2",
    "-iter", "600000", "-salt", "-pass", "env:PITHEAD_FIXTURE_PASS"], {
    input: plain, env: { ...process.env, PITHEAD_FIXTURE_PASS: passphrase },
    maxBuffer: 32 * 1024 * 1024,
  });
  execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
    "-keyout", join(scratch, "key.pem"), "-out", join(scratch, "cert.pem"),
    "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
  { stdio: "ignore" });
  let backupPosts = 0;
  let interrupted = false;
  const server = createServer({ key: await readFile(join(scratch, "key.pem")),
    cert: await readFile(join(scratch, "cert.pem")) }, async (req, res) => {
    if (req.url === "/") {
      res.setHeader("Content-Type", "text/html");
      return res.end(fixture);
    }
    if (req.url === "/api/control/backup" && req.method === "POST") {
      backupPosts++;
      res.writeHead(202, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ id }));
    }
    if (req.url === `/api/control/result?id=${id}`) {
      res.setHeader("Content-Type", "application/json");
      return res.end(JSON.stringify({ status: "applied", archive: archiveName,
        passphrase, contents: ["config.json", "dashboard.db"], ts: 1000 }));
    }
    if (req.url === `/api/control/backup-download?id=${id}`) {
      res.writeHead(200, { "Content-Type": "application/octet-stream",
        "Content-Disposition": `attachment; filename="${archiveName}"`,
        "Content-Length": archive.length });
      if (interrupted) {
        return res.write(archive.subarray(0, 256 * 1024), () => res.destroy());
      }
      return res.end(archive);
    }
    const path = resolve(staticRoot, "." + req.url.replace(/^\/static/, ""));
    if (!req.url.startsWith("/static/") || !path.startsWith(staticRoot + sep)) {
      res.writeHead(404);
      return res.end();
    }
    try {
      const bytes = await readFile(path);
      res.setHeader("Content-Type", "text/javascript");
      res.end(bytes);
    } catch {
      res.writeHead(404);
      res.end();
    }
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  t.after(() => new Promise((r) => { server.closeAllConnections(); server.close(r); }));
  const browser = await chromium.launch({
    // Use the full browser's new headless mode: the headless shell has no certificate UI.
    channel: "chromium",
    ignoreDefaultArgs: disableExtensions ? [] : ["--disable-extensions"],
    args: disableExtensions ? ["--disable-extensions"] : [],
  });
  t.after(() => browser.close());
  console.log(`Backup browser: ${browser.version()}; fresh profile; extensions ${disableExtensions ? "explicitly disabled" : "none installed"}`);
  const context = await browser.newContext({ acceptDownloads: true });
  context.setDefaultTimeout(10000);
  const page = await context.newPage();
  const origin = `https://localhost:${server.address().port}`;
  // Accept the self-signed certificate in the browser itself, without ignoreHTTPSerrors
  // or a certificate-error launch switch (neither proves the operator's acceptance flow).
  await assert.rejects(page.goto(origin), /ERR_CERT_AUTHORITY_INVALID/);
  await page.locator("#details-button").click();
  await page.locator("#proceed-link").click();
  await page.getByRole("button", { name: "Back up now", exact: true }).click();
  await page.getByRole("button", { name: "Create backup", exact: true }).click();
  await page.getByRole("heading", { name: "Backup created", exact: true }).waitFor();
  return { scratch, archive, configBytes, databaseBytes, context, page, origin,
    posts: () => backupPosts, interrupt: (value) => { interrupted = value; } };
}

async function savePair(f) {
  const kitEvent = f.page.waitForEvent("download");
  await f.page.getByRole("link", { name: "Download kit (.txt)", exact: true }).click();
  const kit = await kitEvent;
  assert.equal(await kit.failure(), null);
  assert.equal(kit.suggestedFilename(), "pithead-backup-fixture-kit.txt");
  const kitPath = join(f.scratch, "saved-kit.txt");
  await kit.saveAs(kitPath);
  const kitText = await readFile(kitPath, "utf8");
  assert.match(kitText, new RegExp(`Archive: +${archiveName.replaceAll(".", "\\.")}`));
  const downloadedPassphrase = kitText.match(/^Passphrase: +(.+)$/m)?.[1];
  assert.ok(downloadedPassphrase);
  const archiveEvent = f.page.waitForEvent("download");
  await f.page.getByRole("link", { name: "Download archive", exact: true }).click();
  const download = await archiveEvent;
  assert.equal(await download.failure(), null);
  assert.equal(download.suggestedFilename(), archiveName);
  const archivePath = join(f.scratch, "saved-archive.enc");
  await download.saveAs(archivePath);
  const saved = await readFile(archivePath);
  assert.equal(saved.length, f.archive.length);
  assert.equal(hash(saved), hash(f.archive));
  const decrypted = execFileSync("openssl", ["enc", "-d", "-aes-256-cbc", "-pbkdf2",
    "-iter", "600000", "-pass", "env:PITHEAD_FIXTURE_PASS", "-in", archivePath], {
    env: { ...process.env, PITHEAD_FIXTURE_PASS: downloadedPassphrase },
    maxBuffer: 32 * 1024 * 1024,
  });
  execFileSync("gzip", ["-t"], { input: decrypted });
  const members = execFileSync("tar", ["-tzf", "-"], { input: decrypted }).toString();
  assert.deepEqual(members.trim().split("\n"), ["config.json", "dashboard.db"]);
  for (const [name, want] of [["config.json", f.configBytes], ["dashboard.db", f.databaseBytes]]) {
    const got = execFileSync("tar", ["-xzOf", "-", name], {
      input: decrypted, maxBuffer: 32 * 1024 * 1024,
    });
    assert.equal(hash(got), hash(want));
  }
  assert.equal(f.posts(), 1);
  console.log(`GUI saved both files; encrypted bytes ${saved.length}; SHA-256 matched; downloaded kit decrypted gzip/tar and both members`);
}

for (const disableExtensions of [false, true]) {
  test(`accepted self-signed HTTPS saves both files, extensions disabled=${disableExtensions}`, {
    timeout: 60000,
  }, async (t) => {
    const f = await setup(t, disableExtensions);
    await savePair(f);
    assert.equal(f.page.url(), f.origin + "/");
    await f.page.getByRole("heading", { name: "Backup created", exact: true }).waitFor();
  });
}

test("a client-blocked archive preserves the kit and permits retry without another backup", {
  timeout: 60000,
}, async (t) => {
  const f = await setup(t, true);
  const routePattern = "**/api/control/backup-download?*";
  await f.context.route(routePattern, (route) => route.abort("blockedbyclient"));
  const failed = f.context.waitForEvent("requestfailed", {
    predicate: (req) => req.url().includes("/api/control/backup-download?"),
  });
  await f.page.getByRole("link", { name: "Download archive", exact: true }).click({ noWaitAfter: true });
  const request = await failed;
  assert.match(request.failure().errorText, /ERR_BLOCKED_BY_CLIENT/);
  assert.equal(f.page.url(), f.origin + "/");
  await f.page.getByRole("heading", { name: "Backup created", exact: true }).waitFor();
  await f.context.unroute(routePattern);
  await savePair(f);
  await f.page.getByRole("button", { name: "I've saved it — close", exact: true }).click();
  assert.equal(await f.page.locator(".kit-passphrase").count(), 0);
  assert.equal(await f.page.getByRole("link", { name: "Download kit (.txt)", exact: true }).count(), 0);
});

test("an interrupted archive is a failed download, with the kit still available for a complete retry", {
  timeout: 60000,
}, async (t) => {
  const f = await setup(t, true);
  f.interrupt(true);
  const event = f.page.waitForEvent("download");
  await f.page.getByRole("link", { name: "Download archive", exact: true }).click();
  const download = await event;
  assert.notEqual(await download.failure(), null);
  assert.equal(f.page.url(), f.origin + "/");
  await f.page.getByRole("heading", { name: "Backup created", exact: true }).waitFor();
  f.interrupt(false);
  await savePair(f);
});
