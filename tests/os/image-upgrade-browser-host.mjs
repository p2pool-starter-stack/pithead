#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { promisify } from "node:util";

const run = promisify(execFile);
const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function waitUntil(check, attempts, interval) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (await check()) return;
    await pause(interval);
  }
  assert.fail("bounded wait expired");
}

if (process.argv[2] === "--self-test") {
  let calls = 0;
  await waitUntil(() => ++calls === 2, 2, 0);
  await assert.rejects(
    waitUntil(() => false, 1, 0),
    /bounded wait expired/,
  );
  process.stdout.write("image-upgrade-browser-host self-test: PASS\n");
  process.exit(0);
}

const [origin, key, work, iface] = process.argv.slice(2);
const credentials = await new Promise((resolve, reject) => {
  let body = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => (body += chunk));
  process.stdin.on("end", () => resolve(body));
  process.stdin.on("error", reject);
});
JSON.parse(credentials);
assert.ok(origin && key && work && /^[a-zA-Z0-9_.-]+$/.test(iface));
const host = new URL(origin).hostname;
const sshArgs = [
  "-i",
  key,
  "-o",
  "StrictHostKeyChecking=no",
  "-o",
  "UserKnownHostsFile=/dev/null",
  "-o",
  "ConnectTimeout=5",
  `root@${host}`,
];
const ssh = async (command) =>
  (await run("ssh", [...sshArgs, command], { timeout: 15000 })).stdout.trim();

let child;
let exited;
let childFailed = false;
let stderr = "";
let stage = "initial-ssh";
const cidfile = `${work}.browser.cid`;

async function removeContainer() {
  if (!existsSync(cidfile)) return;
  const cid = readFileSync(cidfile, "utf8").trim();
  if (!/^[0-9a-f]{12,64}$/.test(cid)) {
    rmSync(cidfile, { force: true });
    return;
  }
  try {
    await run("docker", ["rm", "-f", cid], { timeout: 30000 });
  } catch {}
  rmSync(cidfile, { force: true });
}

async function stopChild() {
  if (child && exited && child.exitCode === null) {
    child.kill("SIGTERM");
    const stopped = await Promise.race([exited.then(() => true), pause(10000).then(() => false)]);
    if (!stopped) child.kill("SIGKILL");
    await exited.catch(() => {});
  }
  await removeContainer();
}

process.on("SIGINT", () => stopChild().finally(() => process.exit(130)));
process.on("SIGTERM", () => stopChild().finally(() => process.exit(143)));

try {
  const previousBoot = await ssh("cat /proc/sys/kernel/random/boot_id");
  stage = "browser-start";
  child = spawn(
    "docker",
    [
      "run",
      "--rm",
      "--network",
      "host",
      "--ipc",
      "host",
      "--cidfile",
      cidfile,
      "-i",
      "-v",
      `${work}:/work`,
      "-w",
      "/work",
      "mcr.microsoft.com/playwright@sha256:06a9939e57531807f8d5fd76ce44b53165ffb7d7501d87ab10e285c20b1e971f",
      "bash",
      "-lc",
      'npm ci --ignore-scripts >/dev/null </dev/null && node image-upgrade-browser.mjs "$1"',
      "_",
      origin,
    ],
    { stdio: ["pipe", "pipe", "pipe"] },
  );
  child.stdin.on("error", () => {});
  child.stdin.end(credentials);
  let stdout = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => (stdout += chunk));
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr = `${stderr}${chunk}`.slice(-65536);
  });
  exited = new Promise((resolve) => {
    child.once("error", (error) => {
      childFailed = true;
      resolve({ code: null, error });
    });
    child.once("close", (code) => resolve({ code, error: null }));
  });
  stage = "reboot-request";
  await waitUntil(
    async () => {
      if (childFailed || child.exitCode !== null) throw new Error("browser exited before reboot");
      return existsSync(`${work}/restore-request`);
    },
    240,
    5000,
  );
  stage = "new-boot-observation";
  await waitUntil(
    async () => {
      try {
        return (
          (await ssh(
            `test "$(cat /proc/sys/kernel/random/boot_id)" != "${previousBoot}" && ! ip -6 address show dev ${iface} | grep -qi 'fd00:2463::1' && systemctl is-active --quiet pithead-boot.service && test "$(systemctl show -p Result --value pithead-boot.service)" = success && podman ps --format '{{.Names}}' | grep -qx caddy && echo ready`,
          )) === "ready"
        );
      } catch {
        return false;
      }
    },
    240,
    5000,
  );
  stage = "san-restore";
  await ssh(
    `ip -6 address replace fd00:2463::1/128 dev ${iface} && systemctl start pithead-address-watch.service`,
  );
  await waitUntil(
    async () => {
      try {
        await ssh("systemctl start pithead-address-watch.service");
        return (
          (await ssh(
            "openssl x509 -in /data/pithead/data/tls/wizard.crt -noout -ext subjectAltName | grep -qi 'FD00:2463' && echo ready",
          )) === "ready"
        );
      } catch {
        return false;
      }
    },
    60,
    5000,
  );
  writeFileSync(
    `${work}/restore-complete`,
    "new_boot=true transient_san_absent=true initial_render=true restored_san=true\n",
  );
  stage = "browser-verdict";
  const result = await exited;
  assert.equal(result.error, null);
  assert.equal(result.code, 0);
  await removeContainer();
  process.stdout.write(
    "new boot observation: transient_san_absent=true initial_render=true restored_san=true\n",
  );
  process.stdout.write(stdout);
} catch {
  writeFileSync(`${work}/browser-stderr.log`, stderr, { mode: 0o600 });
  await stopChild();
  process.stderr.write(`image-upgrade browser host orchestration failed at ${stage}\n`);
  process.exitCode = 1;
}
