// Recaptures the launch screenshots in docs/images/launch/ from the real dashboard UI, fed the
// same /api/state fixture the frontend render tests use (state.json) — never hand-drawn mockups.
//
// Not a project dependency — playwright lives in a scratch dir, not package.json, since this is
// a one-off capture tool, not something the app or its test suite imports. Run from the repo root:
//   npm install playwright --prefix /tmp/pw-capture
//   ln -s /tmp/pw-capture/node_modules dashboard/tests/frontend/fixtures/node_modules
//   node dashboard/tests/frontend/fixtures/_capture_launch_images.mjs
//   rm dashboard/tests/frontend/fixtures/node_modules
//
// Regenerate whenever the dashboard UI that these views show changes.
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, "..", "..", "..", "..");
const WEB_ROOT = join(REPO_ROOT, "dashboard", "mining_dashboard", "web");
const SHELL_HTML = join(WEB_ROOT, "templates", "index.html");
const STATIC_DIR = join(WEB_ROOT, "static");
const OUT_DIR = join(REPO_ROOT, "docs", "images", "launch");

const CONTENT_TYPES = {
  ".html": "text/html",
  ".mjs": "text/javascript",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".json": "application/json",
};

const baseState = JSON.parse(
  await readFile(join(HERE, "state.json"), "utf8"),
);
// A syncing variant for the Sync Mode capture: both chains mid-catch-up, miner held — the one
// other top-level shape SyncView (system/syncview.mjs) renders. build_sync's shape is just
// percent/state/current/target per chain, reused as-is from the released fixture.
const syncingState = {
  ...baseState,
  syncing: true,
  sync: {
    monero: { ...baseState.sync.monero, state: "syncing", percent: 64, current: 1920000, remaining: 1080000 },
    tari: { ...baseState.sync.tari, state: "syncing", percent: 30, current: 15000, remaining: 35000 },
  },
};

function makeHandler(state) {
  return (req, res) => {
    const url = new URL(req.url, "http://localhost");
    if (url.pathname === "/") {
      return sendFile(res, SHELL_HTML);
    }
    if (url.pathname === "/api/state") {
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end(JSON.stringify(state));
    }
    if (url.pathname.startsWith("/static/")) {
      return sendFile(res, join(STATIC_DIR, url.pathname.slice("/static/".length)));
    }
    res.writeHead(404);
    res.end();
  };
}

async function sendFile(res, path) {
  try {
    await stat(path);
    const body = await readFile(path);
    res.writeHead(200, {
      "Content-Type": CONTENT_TYPES[extname(path)] || "application/octet-stream",
    });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end();
  }
}

async function listen(handler) {
  const server = createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return server;
}

const server = await listen(makeHandler(baseState));
const syncServer = await listen(makeHandler(syncingState));
const base = `http://127.0.0.1:${server.address().port}`;
const syncBase = `http://127.0.0.1:${syncServer.address().port}`;

const browser = await chromium.launch();

// Retina (2x) for the wide banner/sync shots, 1x full-page for the operational views — matches
// the sizing already documented in docs/images/launch/README.md.
const SHOTS = [
  { name: "hero", path: "/", clip: { x: 0, y: 0, width: 1440, height: 300 }, scale: 2 },
  { name: "simple", path: "/", fullPage: true, scale: 1 },
  { name: "advanced", path: "/", fullPage: true, scale: 1, click: "Advanced" },
  { name: "sync", path: "/", clip: { x: 0, y: 0, width: 1440, height: 668 }, scale: 2, useSyncServer: true },
];

for (const scheme of ["light", "dark"]) {
  for (const shot of SHOTS) {
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      deviceScaleFactor: shot.scale,
      colorScheme: scheme,
    });
    const page = await context.newPage();
    await page.goto((shot.useSyncServer ? syncBase : base) + shot.path);
    await page.waitForSelector(".container:not(:has(.loading))", { timeout: 10_000 });
    if (shot.click) {
      await page.getByRole("button", { name: shot.click, exact: true }).click();
    }
    await page.waitForTimeout(150); // let chart animations/theme transitions settle
    const suffix = scheme === "light" ? "-light" : "";
    const file = join(OUT_DIR, `${shot.name}${suffix}.png`);
    await page.screenshot({
      path: file,
      fullPage: !!shot.fullPage,
      clip: shot.clip,
    });
    console.log("wrote", file);
    await context.close();
  }
}

// Demo GIF: a scroll tour of the Advanced view, recorded headless via Playwright's video capture
// and converted with ffmpeg (both already on PATH — no new tooling).
const videoDir = join(OUT_DIR, ".video-tmp");
const tourContext = await browser.newContext({
  viewport: { width: 1200, height: 676 },
  recordVideo: { dir: videoDir, size: { width: 1200, height: 676 } },
});
const tourPage = await tourContext.newPage();
await tourPage.goto(base + "/");
await tourPage.waitForSelector(".container:not(:has(.loading))", { timeout: 10_000 });
await tourPage.getByRole("button", { name: "Advanced", exact: true }).click();
await tourPage.waitForTimeout(500);
const scrollHeight = await tourPage.evaluate(() => document.body.scrollHeight);
const steps = 20;
for (let i = 1; i <= steps; i++) {
  await tourPage.mouse.wheel(0, (scrollHeight / steps));
  await tourPage.waitForTimeout(520); // ~12s total tour
}
const video = tourPage.video();
await tourContext.close();
const webmPath = await video.path();

const gifPath = join(OUT_DIR, "demo.gif");
const { execFileSync } = await import("node:child_process");
try {
  execFileSync("ffmpeg", [
    "-y",
    "-i", webmPath,
    "-vf", "fps=12,scale=600:338:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
    "-loop", "0",
    gifPath,
  ], { stdio: "inherit" });
  console.log("wrote", gifPath);
} catch (err) {
  console.error("ffmpeg conversion failed, demo.gif not regenerated:", err.message);
}
await import("node:fs/promises").then((fs) => fs.rm(videoDir, { recursive: true, force: true }));

await browser.close();
server.close();
syncServer.close();
