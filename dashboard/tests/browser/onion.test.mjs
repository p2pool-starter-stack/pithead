import { expect, test } from "./fixtures.mjs";

const address = `http://${"a".repeat(56)}.onion`;
const key = "synthetic-private-client-key";

test.beforeEach(async ({ page, ui }) => {
  ui.state.control_enabled = true;
  ui.state.dashboard_onion = { url: address, client_auth: true };
  await page.route("**/api/miner-connection", (route) =>
    route.fulfill({ json: { url: "stratum+tcp://example.invalid:3333", password_set: false } }),
  );
});

test("client key reveal is explicit, blocks duplicate requests, and clears on close and reload", async ({
  page,
  ui,
}) => {
  let requests = 0;
  let ready = false;
  await page.route("**/api/control/onion-client-key", (route) => {
    requests++;
    expect(route.request().method()).toBe("POST");
    expect(route.request().headers()["x-pithead-control"]).toBe("1");
    return route.fulfill({ status: 202, json: { id: "onion-key" } });
  });
  await page.route("**/api/control/result?id=onion-key", (route) =>
    route.fulfill({
      json: ready
        ? { status: "applied", client_key: key, torrc_line: `synthetic-onion:descriptor:${key}` }
        : { status: "running" },
    }),
  );
  await page.clock.install();
  await ui.open();
  await expect(page.getByText(address, { exact: true })).toBeVisible();
  expect(requests).toBe(0);
  await expect(page.getByText(key, { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Show client key", exact: true }).click();
  await expect(page.getByRole("button", { name: "Fetching…", exact: true })).toBeDisabled();
  ready = true;
  await page.clock.fastForward(2000);
  await expect(page.getByText(key, { exact: true })).toBeVisible();
  expect(requests).toBe(1);
  await page.getByRole("button", { name: "I've saved it — close", exact: true }).click();
  await expect(page.getByText(key, { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Show client key", exact: true }).click();
  await expect(page.getByRole("button", { name: "Fetching…", exact: true })).toBeDisabled();
  await page.clock.fastForward(2000);
  await expect(page.getByText(key, { exact: true })).toBeVisible();
  expect(requests).toBe(2);
  await page.reload();
  await expect(page.getByRole("button", { name: "Show client key", exact: true })).toBeVisible();
  await expect(page.getByText(key, { exact: true })).toHaveCount(0);
  expect(requests).toBe(2);
});

test("a refused client-key request displays the failure and can be retried", async ({
  page,
  ui,
}) => {
  let attempts = 0;
  await page.route("**/api/control/onion-client-key", (route) =>
    ++attempts === 1
      ? route.fulfill({ status: 403 })
      : route.fulfill({ status: 202, json: { id: "key-retry" } }),
  );
  await page.route("**/api/control/result?id=key-retry", (route) =>
    route.fulfill({ json: { status: "failed", error: "Client authorization is disabled." } }),
  );
  await ui.open();
  const reveal = page.getByRole("button", { name: "Show client key", exact: true });
  await reveal.click();
  await expect(page.getByText("HTTP 403", { exact: true })).toBeVisible();
  await expect(reveal).toBeEnabled();
  await reveal.click();
  await expect(page.getByText("Client authorization is disabled.", { exact: true })).toBeVisible();
  await expect(page.getByText("HTTP 403", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Tor client key" })).toHaveCount(0);
  expect(attempts).toBe(2);
});

test("copy feedback follows the clipboard result and never changes the action's name", async ({
  page,
  ui,
}) => {
  // Browsers differ in clipboard permission automation; stub only the platform boundary.
  await page.addInitScript(() => {
    window.copiedText = [];
    window.denyCopy = false;
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: async (text) => {
          if (window.denyCopy) throw new Error("Permission denied");
          window.copiedText.push(text);
        },
      },
    });
  });
  await page.clock.install();
  await ui.open();
  const copy = page.getByRole("button", { name: "Copy address", exact: true });
  const confirmation = page.getByRole("status").filter({ hasText: /^Copied$/ });
  await copy.click();
  await expect(confirmation).toBeVisible();
  expect(await page.evaluate(() => window.copiedText)).toEqual([address]);
  await expect(copy).toBeEnabled();
  await page.clock.fastForward(4000);
  await expect(confirmation).toHaveCount(0);
  await copy.click();
  await expect(confirmation).toBeVisible();
  await page.evaluate(() => {
    window.denyCopy = true;
  });
  await copy.click();
  await expect(confirmation).toHaveCount(0);
  expect(await page.evaluate(() => window.copiedText)).toEqual([address, address]);
});

test("read-only dashboards explain the CLI key path without offering a control request", async ({
  page,
  ui,
}) => {
  ui.state.control_enabled = false;
  const mutations = [];
  page.on("request", (request) => {
    if (request.method() !== "GET") mutations.push(request.url());
  });
  await ui.open();
  await expect(page.getByText("pithead onion-client-key", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Show client key", exact: true })).toHaveCount(0);
  expect(mutations).toEqual([]);
});
