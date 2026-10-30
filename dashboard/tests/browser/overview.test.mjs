import { expect, test } from "./fixtures.mjs";

function healthy(ui) {
  const now = Date.now();
  ui.state.backup_status = { state: "success", last_success_at: now / 1000 };
  ui.state.pool_tier_suggestion = null;
  ui.state.monero.health.level = "green";
  ui.state.badges = [];
  ui.state.db_healthy = true;
  ui.state.overview = {
    snapshot_ts: now / 1000,
    shares_found: 3,
    shares_failed: 0,
    hashrate_now: "1.5 kH/s",
    hashrate_24h: "1.5 kH/s",
    system_available: false,
    tari_enabled: false,
    xvb_enabled: false,
    last_payout: { ts: now / 1000 - 3600, amount: 1000000000 },
  };
  ui.state.sync.monero.state = "done";
  ui.state.syncing = false;
  ui.state.workers = [{ name: "rig-alpha", status: "online", h60: 1500 }];
  ui.state.chart = {
    p2pool: [
      { x: now - 3600000, y: 1500 },
      { x: now - 1800000, y: null },
      { x: now, y: 1400 },
    ],
    xvb: [
      { x: now - 3600000, y: 0 },
      { x: now - 1800000, y: null },
      { x: now, y: 0 },
    ],
    payouts: [{ x: now - 600000, y: 0.9 }],
  };
}

for (const theme of ["light", "dark", "auto"]) {
  test(`Overview readings, one control, keyboard chart and screenshots in ${theme}`, async ({
    page,
    ui,
  }, info) => {
    healthy(ui);
    await page.route("**/api/state**", async (route) => {
      const query = new URL(route.request().url()).searchParams;
      const snapshot = structuredClone(ui.state);
      snapshot.window =
        query.has("from") && query.has("to")
          ? { from: Number(query.get("from")), to: Number(query.get("to")) }
          : null;
      await route.fulfill({ json: snapshot });
    });
    await page.addInitScript((value) => localStorage.setItem("dashboardTheme", value), theme);
    await page.emulateMedia({ colorScheme: "dark", reducedMotion: "reduce" });
    await ui.openPreview();
    await expect(page.getByText("Everything is running normally", { exact: true })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Last payout", exact: true })).toBeVisible();
    await expect(page.getByText("0.001000 XMR", { exact: true })).toBeVisible();
    await expect(page.getByRole("link", { name: "Rigs · 1 of 1 mining" })).toBeVisible();
    const main = page.getByRole("main");
    await expect(main.locator("select:visible, button:visible, input:visible")).toHaveCount(1);
    await expect(main.getByRole("heading", { name: "Estimated earnings" })).toHaveCount(0);
    await expect(main.getByRole("button", { name: /Reset|Show all|Show less/ })).toHaveCount(0);
    await page.getByLabel("Chart range").selectOption("1w");
    await expect.poll(() => new URL(page.url()).searchParams.get("range")).toBe("1w");
    const canvas = main.getByRole("img", {
      name: "Hashrate over real time with confirmed payout markers",
    });
    await canvas.focus();
    await page.keyboard.press("+");
    await expect.poll(() => new URL(page.url()).searchParams.has("from")).toBe(true);
    await page.keyboard.press("Home");
    await expect.poll(() => new URL(page.url()).searchParams.has("from")).toBe(false);
    expect(
      await canvas.evaluate((node) => {
        const instance = Chart.getChart(node);
        instance.zoom(1.5, "none");
        return instance.isZoomedOrPanned();
      }),
    ).toBe(true);
    await canvas.focus();
    await page.keyboard.press("Home");
    await expect
      .poll(() => canvas.evaluate((node) => Chart.getChart(node).isZoomedOrPanned()))
      .toBe(false);
    for (const width of [375, 768, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(
        true,
      );
      await page.screenshot({
        path: info.outputPath(`overview-${theme}-${width}.png`),
        fullPage: true,
        animations: "disabled",
      });
    }
    await page.getByRole("link", { name: /^Confirmed payout ·/ }).click();
    await expect(page.getByRole("dialog", { name: "Advanced", exact: true })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Activity", exact: true })).toBeVisible();
  });
}

test("stale partial fleet and off destinations do not look healthy", async ({ page, ui }) => {
  healthy(ui);
  ui.state.overview.snapshot_ts -= 300;
  ui.state.workers.push({ name: "rig-beta", status: "offline", h60: null });
  await ui.openPreview();
  await expect(page.getByText(/Snapshot freshness is unavailable or stale/)).toBeVisible();
  await expect(page.getByRole("link", { name: "Rigs · 1 of 2 mining" })).toBeVisible();
  await expect(
    page.getByRole("link", { name: "rig-beta: offline. Check its connection." }),
  ).toBeVisible();
  await expect(page.getByRole("list", { name: "Where the hashrate went" })).toHaveCount(0);
  await expect(page.getByText("Everything is running normally", { exact: true })).toHaveCount(0);
});

test("pending producer evidence stays unavailable while real pool suggestions and backup links route", async ({
  page,
  ui,
}) => {
  healthy(ui);
  delete ui.state.backup_status;
  delete ui.state.pool_tier_suggestion;
  await ui.openPreview();
  const attention = page.getByRole("region", { name: "Attention", exact: true });
  await expect(
    attention.getByRole("link", {
      name: "Backup history is unavailable. Review or create a recovery backup.",
    }),
  ).toBeVisible();
  await expect(
    attention.getByText("Pool-tier advice is unavailable.", { exact: false }),
  ).toBeVisible();
  await expect(attention.getByText(/No backup|No successful backup|never backed up/)).toHaveCount(
    0,
  );
  await attention.getByRole("link", { name: "Review pool and rig settings" }).click();
  await expect.poll(() => new URL(page.url()).searchParams.get("advanced")).toBe("pool-and-rigs");
  await expect(
    page
      .getByRole("dialog", { name: "Advanced", exact: true })
      .getByRole("heading", { name: "Pool and rigs", exact: true }),
  ).toBeVisible();
});

test("producer-backed provisional pool advice is a deep link and never changes the pool", async ({
  page,
  ui,
}) => {
  healthy(ui);
  ui.state.pool_tier_suggestion = { tier: "nano", hashrate_24h: 5000, provisional: true };
  const configured = ui.state.pool.type;
  await ui.openPreview();
  await expect(
    page.getByRole("link", { name: /Provisional suggestion: review nano/ }),
  ).toBeVisible();
  await page.getByRole("link", { name: /Provisional suggestion: review nano/ }).click();
  await expect.poll(() => new URL(page.url()).searchParams.get("advanced")).toBe("pool-and-rigs");
  expect(ui.state.pool.type).toBe(configured);
});
