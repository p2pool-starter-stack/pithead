import { randomBytes } from "node:crypto";
import { expect, test } from "./fixtures.mjs";

test.describe.configure({ mode: "serial" });

const loginPassword = randomBytes(18).toString("base64url");
const replacementPassword = randomBytes(18).toString("base64url");

test("login gives one generic failure and submits only to the local session endpoint", async ({
  page,
  ui,
}) => {
  await page.route("**/login", (route) =>
    route.request().method() === "POST"
      ? route.fulfill({ status: 401, json: { error: "Invalid username or password." } })
      : route.continue(),
  );
  await ui.openLogin();
  await expect(page.getByRole("heading", { name: "Sign in to your stack" })).toBeVisible();
  await expect(page.getByRole("alert")).toBeHidden();
  const request = page.waitForRequest(
    (candidate) => new URL(candidate.url()).pathname === "/login" && candidate.method() === "POST",
  );
  await page.getByLabel("Username").fill("fixture-viewer");
  await page.getByLabel("Password").fill(loginPassword);
  await page.getByRole("button", { name: "Sign in" }).click({ noWaitAfter: true });
  const submitted = await request;
  expect(submitted.postData()).toBe(
    `username=fixture-viewer&password=${encodeURIComponent(loginPassword)}`,
  );
  await expect(page.getByRole("alert")).toHaveText(
    "The username or password is incorrect. Try again.",
  );
});

for (const theme of ["light", "dark"]) {
  test(`capture login in ${theme} theme`, async ({ page, ui }, testInfo) => {
    await ui.openLogin();
    await page.evaluate((value) => localStorage.setItem("dashboardTheme", value), theme);
    await page.reload();
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
    const screenshot = await page.screenshot({
      path: testInfo.outputPath(`login-${theme}.png`),
      animations: "disabled",
    });
    await testInfo.attach(`login-${theme}`, { body: screenshot, contentType: "image/png" });
  });
}

test("capture phone login", async ({ page, ui }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await ui.openLogin();
  await expect(page.locator(".login-card")).toHaveCSS("min-height", "844px");
  const screenshot = await page.screenshot({
    path: testInfo.outputPath("login-phone.png"),
    animations: "disabled",
  });
  await testInfo.attach("login-phone", { body: screenshot, contentType: "image/png" });
});

test("viewer can open every view but dashboard mutations stay unavailable", async ({
  page,
  ui,
}, testInfo) => {
  ui.state.auth = { enabled: true, user: "fixture-viewer", role: "viewer" };
  ui.state.control_enabled = false;
  ui.state.host_ip = "";
  ui.state.host_addr = "";
  ui.state.dashboard_onion = null;
  await page.route("**/api/miner-connection", (route) =>
    route.fulfill({
      json: { url: "", password_set: false, tls: false },
    }),
  );
  await page.route("**/api/config", (route) =>
    route.fulfill({
      json: {
        dashboard: {
          auth: {
            users: [{ name: "fixture-admin", role: "admin", password_hash: { __secret__: true } }],
          },
        },
        p2pool: { pool: "mini" },
        _editable_keys: ["dashboard.auth.users", "p2pool.pool"],
      },
    }),
  );
  await page.route("**/api/worker?**", (route) =>
    route.fulfill({
      json: {
        name: "rig-alpha",
        found: true,
        editable: true,
        control_enabled: true,
        status: "mining",
        hashrate: "1.2 kH/s",
        rigforge: null,
        writable_keys: ["DONATION"],
        rig_config: { DONATION: 5 },
        last_applied: {},
        history: [],
        hashrate_by_config: [],
        hashrate_history: { hashrate: [], markers: [] },
      },
    }),
  );
  const mutations = [];
  page.on("request", (request) => {
    if (request.method() !== "GET") mutations.push(request.url());
  });
  await ui.open();
  await expect(page.getByText("fixture-viewer", { exact: true })).toBeVisible();
  await expect(page.getByText("Read-only", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "rig-alpha", exact: true }).click();
  const inspector = page.getByRole("dialog", { name: "Worker rig-alpha" });
  await expect(inspector.getByText("mining", { exact: true })).toBeVisible();
  await expect(inspector.getByRole("heading", { name: "History" })).toBeVisible();
  await expect(inspector.getByRole("spinbutton", { name: "DONATION" })).toHaveCount(0);
  await expect(inspector.getByRole("button", { name: /Apply|Adopt|Upgrade/ })).toHaveCount(0);
  await inspector.getByRole("button", { name: "Close" }).click();
  const views = page.getByRole("group", { name: "Dashboard view" });
  for (const name of ["Advanced", "Configuration", "Backup", "Simple"]) {
    await views.getByRole("button", { name, exact: true }).click();
  }
  await views.getByRole("button", { name: "Configuration", exact: true }).click();
  await expect(page.getByText("Read-only account.")).toBeVisible();
  await expect(page.locator("textarea.worker-edit")).toBeDisabled();
  await expect(page.getByRole("button", { name: "Add account" })).toBeDisabled();
  await views.getByRole("button", { name: "Backup", exact: true }).click();
  await expect(page.getByRole("button", { name: "Back up now" })).toHaveCount(0);
  expect(mutations).toEqual([]);
  await views.getByRole("button", { name: "Configuration", exact: true }).click();
  await page.evaluate(() => window.scrollTo(0, 0));
  const screenshot = await page.screenshot({
    path: testInfo.outputPath("viewer-dashboard.png"),
    animations: "disabled",
  });
  await testInfo.attach("viewer-dashboard", { body: screenshot, contentType: "image/png" });
});

test("admin hashes a password before it enters the configuration draft", async ({ page, ui }) => {
  ui.state.auth = { enabled: true, user: "fixture-admin", role: "admin" };
  ui.state.control_enabled = true;
  await page.route("**/api/miner-connection", (route) =>
    route.fulfill({
      json: { url: "", password_set: false, tls: false },
    }),
  );
  await page.route("**/api/config", (route) =>
    route.fulfill({
      json: {
        dashboard: {
          auth: {
            users: [{ name: "fixture-admin", role: "admin", password_hash: { __secret__: true } }],
          },
        },
        _editable_keys: ["dashboard.auth.users"],
      },
    }),
  );
  let hashBody;
  await page.route("**/api/auth/hash", async (route) => {
    hashBody = route.request().postDataJSON();
    await route.fulfill({ json: { password_hash: "$2b$fixture-hash" } });
  });
  await ui.open();
  await page
    .getByRole("group", { name: "Dashboard view" })
    .getByRole("button", { name: "Configuration", exact: true })
    .click();
  await page.getByLabel("New password").fill("short");
  await expect(page.getByRole("button", { name: "Set password" })).toBeDisabled();
  await page.getByLabel("New password").fill(replacementPassword);
  await page.getByRole("button", { name: "Set password" }).click();
  expect(hashBody).toEqual({ password: replacementPassword });
  await expect(page.getByLabel("New password")).toHaveValue("");
  await expect(page.locator("textarea.worker-edit")).toHaveValue(/\$2b\$fixture-hash/);
  await expect(page.locator("textarea.worker-edit")).not.toHaveValue(
    new RegExp(replacementPassword),
  );
});
