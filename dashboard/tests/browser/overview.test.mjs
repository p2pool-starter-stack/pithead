import { expect, test } from "./fixtures.mjs";

function healthy(ui) {
  const now = Date.now();
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
