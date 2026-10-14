import { expect, test } from "./fixtures.mjs";

test.beforeEach(async ({ page }) => {
  await page.route("**/api/miner-connection", (route) =>
    route.fulfill({
      json: {
        url: "stratum+tcp://example.invalid:3333",
        password_set: false,
        tls: false,
      },
    }),
  );
});

test("appliance controls are reachable through dashboard navigation without side effects", async ({
  page,
  ui,
}) => {
  ui.state.control_enabled = true;
  ui.state.os_update = { step: "idle" };
  const mutations = [];
  page.on("request", (request) => {
    if (request.method() !== "GET") mutations.push(request.url());
  });
  await page.route("**/api/config", (route) =>
    route.fulfill({
      json: {
        p2pool: { pool: "mini" },
        _core_keys: ["p2pool.pool"],
        _editable_keys: ["p2pool.pool"],
      },
    }),
  );
  await page.route("**/api/access", (route) => route.fulfill({ json: { entries: [] } }));
  await page.route("**/api/audit", (route) => route.fulfill({ json: { entries: [] } }));
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
  await ui.open();
  await page.getByRole("button", { name: "rig-alpha", exact: true }).click();
  const worker = page.getByRole("dialog", { name: "Worker rig-alpha" });
  await expect(worker.getByRole("spinbutton", { name: "DONATION" })).toHaveValue("5");
  await page.keyboard.press("Escape");
  await expect(worker).toHaveCount(0);
  const views = page.getByRole("group", { name: "Dashboard view" });
  await views.getByRole("button", { name: "Configuration", exact: true }).click();
  await expect(page.getByRole("combobox", { name: /^p2pool\.pool/ })).toHaveValue("mini");
  await expect(page.getByRole("button", { name: "Run health check" })).toBeEnabled();
  await views.getByRole("button", { name: "Backup", exact: true }).click();
  await page.getByRole("button", { name: "Back up now" }).click();
  const backup = page.getByRole("dialog", { name: "Create a backup" });
  await backup.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(backup).toHaveCount(0);
  await page.getByRole("button", { name: /^OS update/ }).click();
  const update = page.getByRole("dialog", { name: "System update" });
  await update.getByRole("button", { name: "Close", exact: true }).click();
  await expect(update).toHaveCount(0);
  await views.getByRole("button", { name: "Simple", exact: true }).click();
  await expect(page.getByRole("button", { name: "rig-alpha", exact: true })).toBeVisible();
  expect(mutations).toEqual([]);
});

test("view, theme, chart range, averaging and hidden series survive reload", async ({
  page,
  ui,
  isMobile,
}) => {
  await ui.open();
  const views = page.getByRole("group", { name: "Dashboard view" });
  await views.getByRole("button", { name: "Advanced", exact: true }).click();
  await page
    .getByRole("group", { name: "Theme", exact: true })
    .getByRole("button", { name: "Light", exact: true })
    .click();
  if (isMobile)
    await page.getByRole("combobox", { name: "Range", exact: true }).selectOption("24h");
  else
    await page
      .getByRole("group", { name: "Chart range", exact: true })
      .getByRole("button", { name: "24 Hr", exact: true })
      .click();
  await expect(page).toHaveURL(/\?range=24h$/);
  const refreshed = page.waitForResponse((res) =>
    res.url().includes("/api/state?range=24h&avg=1h"),
  );
  if (isMobile) await page.getByRole("combobox", { name: "Avg", exact: true }).selectOption("1h");
  else
    await page
      .getByRole("group", { name: "Hashrate averaging window" })
      .getByRole("button", { name: "1 Hr", exact: true })
      .click();
  await refreshed;
  const series = page.getByRole("group", { name: "Toggle series" }).getByRole("button").first();
  const seriesName = await series.innerText();
  await series.click();
  await expect(series).toHaveAttribute("aria-pressed", "false");
  await page.reload();
  await expect(views.getByRole("button", { name: "Advanced", exact: true })).toHaveAttribute(
    "aria-pressed",
    "true",
  );
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  await expect(
    page
      .getByRole("group", { name: "Toggle series" })
      .getByRole("button", { name: seriesName, exact: true }),
  ).toHaveAttribute("aria-pressed", "false");
  if (isMobile)
    await expect(page.getByRole("combobox", { name: "Avg", exact: true })).toHaveValue("1h");
  else
    await expect(
      page
        .getByRole("group", { name: "Hashrate averaging window" })
        .getByRole("button", { name: "1 Hr", exact: true }),
    ).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByRole("img", { name: /hashrate/i }).first()).toBeVisible();
  await views.getByRole("button", { name: "Simple", exact: true }).click();
  await expect(views.getByRole("button", { name: "Simple", exact: true })).toHaveAttribute(
    "aria-pressed",
    "true",
  );
});

test("repeated refresh failures retain data, explain recovery, then clear on success", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  await ui.open();
  await expect(page.getByRole("heading", { name: "Connect a miner" })).toBeVisible();
  await page.route("**/api/state?**", (route) => route.fulfill({ status: 503 }));
  await page.clock.fastForward(30000);
  await expect(page.getByText(/Disconnected — showing data/)).toBeVisible();
  await expect(page.getByText(/Retries have not restored/)).toHaveCount(0);
  await expect(page.getByRole("group", { name: "Dashboard view" })).toBeVisible();
  await page.clock.fastForward(60000);
  await expect(page.getByText(/Retries have not restored/)).toBeVisible();
  await expect(page.getByText(/Stop if they do not\s+match/)).toBeVisible();
  await page.unroute("**/api/state?**");
  await page.clock.fastForward(30000);
  await expect(page.getByText(/Disconnected — showing data/)).toHaveCount(0);
  await expect(page.getByText(/Retries have not restored/)).toHaveCount(0);
});

test("failed first load can recover without reloading or losing the theme", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  await page.route("**/api/state?**", (route) => route.abort());
  await ui.open();
  await expect(page.getByText("Cannot reach the dashboard.", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Dark", exact: true }).click();
  await page.unroute("**/api/state?**");
  await page.clock.fastForward(30000);
  await expect(page.getByRole("group", { name: "Dashboard view" })).toBeVisible();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await expect(page.getByText("Cannot reach the dashboard.", { exact: true })).toHaveCount(0);
});

test("miner credentials start hidden and can be revealed and hidden without editing", async ({
  page,
  ui,
}) => {
  await page.route("**/api/miner-connection", (route) =>
    route.fulfill({
      json: {
        url: "stratum+ssl://example.invalid:3334",
        password_set: true,
        password: "synthetic-password",
        tls: true,
        fingerprint: "synthetic-fingerprint",
      },
    }),
  );
  await ui.open();
  const password = page.getByLabel("Stratum password", { exact: true });
  await expect(password).toHaveAttribute("type", "password");
  await expect(password).not.toBeEditable();
  await page.getByRole("button", { name: "Reveal", exact: true }).click();
  await expect(password).toHaveAttribute("type", "text");
  await expect(password).toHaveValue("synthetic-password");
  await page.getByRole("button", { name: "Hide", exact: true }).click();
  await expect(password).toHaveAttribute("type", "password");
  await page.reload();
  await expect(password).toHaveAttribute("type", "password");
});
