import { expect, test } from "./fixtures.mjs";

function syncing(ui, tari = false) {
  ui.state.syncing = true;
  ui.state.tari_gates_sync = tari;
  ui.state.sync = {
    monero: { state: "syncing", percent: 50, current: 1000, target: 2000, remaining: 1000 },
  };
  ui.state.sync_status = {
    sampled_at: Date.now() / 1000,
    chains: { monero: { local: true, reachable: true, synced: false, healthy: false } },
    mining: { held: true, released: false, workers_rejected: false, fail_closed: false },
  };
  if (tari) {
    ui.state.sync.tari = { state: "loading", current: 100, target: 0 };
    ui.state.sync_status.chains.tari = {
      local: false,
      node: "remote-node.example:18142",
      reachable: true,
      synced: false,
      base_node_state: "HEADER_SYNC",
      initial_sync_achieved: false,
      wait_seconds: 720,
    };
  }
}

for (const platform of ["appliance", "diy-login", "diy-readonly"]) {
  test(`sync is read-only on ${platform}, hides off Tari and hands over automatically`, async ({
    page,
    ui,
  }) => {
    await page.clock.install();
    syncing(ui);
    ui.state.control_enabled = platform !== "diy-readonly";
    ui.state.os_update = platform === "appliance" ? {} : null;
    await ui.openPreview();
    const view = page.getByRole("region", { name: "Getting ready to mine" });
    await expect(view).toBeVisible();
    await expect(view.getByText("50% · Estimate unavailable", { exact: true })).toBeVisible();
    await expect(view.getByText(/Tari/)).toHaveCount(0);
    await expect(view.locator("button,input,select,textarea")).toHaveCount(0);
    await expect(view.getByText(/1,000 \/ 2,000/)).toBeVisible();
    for (const current of [1100, 1200]) {
      Object.assign(ui.state.sync.monero, {
        current,
        remaining: 2000 - current,
        percent: current / 20,
      });
      ui.state.sync_status.sampled_at += 30;
      await page.clock.fastForward(30000);
    }
    await expect(view.getByText(/Roughly 4 min left/)).toBeVisible();
    ui.state.syncing = false;
    ui.state.sync.monero.state = "done";
    ui.state.sync_status.chains.monero.synced = true;
    ui.state.sync_status.mining = {
      released: true,
      held: false,
      workers_rejected: false,
      fail_closed: false,
    };
    ui.state.sync_status.sampled_at += 30;
    await page.clock.fastForward(30000);
    await expect(view).toHaveCount(0);
    await expect(
      page
        .getByText(
          "This page is being built for the new interface. Continue using the current dashboard until cutover.",
          { exact: true },
        )
        .first(),
    ).toBeVisible();
    ui.state.sync_status.chains.monero.health = { level: "red", reason: "No peers" };
    ui.state.sync_status.mining.workers_rejected = true;
    ui.state.sync_status.chains.monero.recovery_remaining = 45;
    ui.state.sync_status.sampled_at += 30;
    await page.clock.fastForward(30000);
    await expect(view).toBeVisible();
    await expect(view.getByText(/recovery window, then worker re-admission/)).toBeVisible();
    await expect(view.getByText(/No peers/)).toBeVisible();
    await expect(view.getByText(/Recovery window:/)).toBeVisible();
  });
}

test("remote-Tari wait, error, disconnect and reload preserve the snapshot and age", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  syncing(ui, true);
  await ui.openPreview();
  const view = page.getByRole("region", { name: "Getting ready to mine" });
  await expect(view.getByText(/remote-node.example:18142/)).toBeVisible();
  await expect(view.getByText(/HEADER_SYNC.*not yet achieved.*12 min/)).toBeVisible();
  ui.state.sync_status.chains.tari.error = "GetTipInfo probe failed";
  ui.state.sync_status.chains.tari.reachable = false;
  await page.clock.fastForward(30000);
  await expect(view.getByText(/Last probe error: GetTipInfo probe failed/)).toBeVisible();
  await page.route("**/api/state?**", (route) => route.fulfill({ status: 503 }));
  await page.clock.fastForward(120000);
  await expect(view.getByText(/Disconnected.*Sample age:/)).toBeVisible();
  await page.reload();
  await expect(view.getByText(/remote-node.example:18142/)).toBeVisible();
  await expect(view.getByText(/Last probe error: GetTipInfo probe failed/)).toBeVisible();
  await expect(view.getByText(/Disconnected.*Sample age:/)).toBeVisible();
  await expect(view.locator("button,input,select")).toHaveCount(0);
});

for (const theme of ["light", "dark"]) {
  test(`sync visual proof and contrast in ${theme}`, async ({ page, ui }, info) => {
    await page.addInitScript((value) => localStorage.setItem("dashboardTheme", value), theme);
    syncing(ui, true);
    ui.state.profile = { name: "Performance" };
    await ui.openPreview();
    await expect(page.getByRole("link", { name: /Performance syncs faster/ })).toBeVisible();
    for (const width of [375, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(
        true,
      );
      await page.screenshot({
        path: info.outputPath(`shell-sync-${theme}-${width}.png`),
        fullPage: true,
      });
    }
    const failures = await page.locator(".sync-overview").evaluate((root) => {
      const lum = (text) =>
        text
          .match(/[\d.]+/g)
          .slice(0, 3)
          .map(Number)
          .map((v) => v / 255)
          .map((v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4))
          .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
      const failures = [];
      for (const element of root.querySelectorAll("h2,h3,p,dt,dd,a,span")) {
        let background = element;
        while (
          background.parentElement &&
          getComputedStyle(background).backgroundColor === "rgba(0, 0, 0, 0)"
        )
          background = background.parentElement;
        const a = lum(getComputedStyle(element).color),
          b = lum(getComputedStyle(background).backgroundColor);
        if ((Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05) < 4.5) failures.push(element.tagName);
      }
      return failures;
    });
    expect(failures).toEqual([]);
    await page.getByRole("link", { name: /Performance syncs faster/ }).focus();
    await expect(page.getByRole("link", { name: /Performance syncs faster/ })).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page.getByRole("heading", { name: "Settings", level: 1 })).toBeVisible();
  });
}
