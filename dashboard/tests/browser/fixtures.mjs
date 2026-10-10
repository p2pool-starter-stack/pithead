import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { test as base, expect } from "@playwright/test";

const webRoot = fileURLToPath(new URL("../../mining_dashboard/web/", import.meta.url));
// Keep the old implementation override for negative-control runs.
const staticRoot = resolve(process.env.PITHEAD_BROWSER_STATIC || resolve(webRoot, "static"));
const template = await readFile(resolve(webRoot, "templates/index.html"), "utf8");
const wizardTemplate = await readFile(resolve(webRoot, "templates/wizard.html"), "utf8");
const initialState = JSON.parse(
  await readFile(new URL("../frontend/fixtures/state.json", import.meta.url), "utf8"),
);
const types = {
  ".mjs": "text/javascript",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".json": "application/json",
};

export { expect };

// Every test gets a real production page, its own state, and a loopback-only server.
// API routes in a test model the host response; they never invoke host control commands.
export const test = base.extend({
  ui: async ({ page, context }, use) => {
    const state = structuredClone(initialState);
    const responses = new Map();
    let fixture = "";
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const server = createServer(async (req, res) => {
      try {
        const response = responses.get(req.url);
        if (response) {
          res.writeHead(response.status || 200, response.headers);
          return res.end(response.body);
        }
        const path = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
        if (path === "/" || path === "/fixture" || path === "/setup") {
          res.writeHead(200, { "Content-Type": "text/html" });
          return res.end(path === "/" ? template : path === "/setup" ? wizardTemplate : fixture);
        }
        if (path === "/api/state") {
          res.writeHead(200, { "Content-Type": "application/json" });
          return res.end(JSON.stringify(state));
        }
        if (path.startsWith("/static/")) {
          const file = resolve(staticRoot, path.slice("/static/".length));
          if (file.startsWith(staticRoot + sep)) {
            const body = await readFile(file);
            res.writeHead(200, {
              "Content-Type": types[extname(file)] || "application/octet-stream",
            });
            return res.end(body);
          }
        }
      } catch (error) {
        if (error.code !== "ENOENT" && !(error instanceof URIError)) {
          errors.push(`Fixture server: ${error.message}`);
        }
      }
      res.writeHead(404);
      res.end();
    });
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const origin = `http://127.0.0.1:${server.address().port}`;
    // Page API mocks take precedence over context routes; observe requests independently.
    context.on("request", (request) => {
      if (new URL(request.url()).origin !== origin) {
        errors.push(`Unexpected external request: ${request.url()}`);
      }
    });
    await context.route("**/*", async (route) => {
      if (new URL(route.request().url()).origin === origin) return route.continue();
      errors.push(`Unexpected external request: ${route.request().url()}`);
      await route.abort();
    });
    page.on("response", (response) => {
      if (new URL(response.url()).pathname.startsWith("/static/") && !response.ok()) {
        errors.push(`Asset failed: ${response.status()} ${response.url()}`);
      }
    });
    try {
      await use({
        state,
        responses,
        open: () => page.goto(origin),
        openWizard: () => page.goto(`${origin}/setup`),
        mount: async (script) => {
          fixture = `<!doctype html><html lang="en"><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="/static/dashboard.css"></head><body>
<div id="fixture" class="container"></div><script type="module">
import { html, render } from '/static/app/preact.mjs';
${script}
</script></body></html>`;
          await page.goto(`${origin}/fixture`);
        },
      });
      expect(errors, "uncaught browser errors, missing assets, or external traffic").toEqual([]);
    } finally {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    }
  },
});
