import { expect, test } from "./fixtures.mjs";

const config = {
  xvb: { enabled: false },
  dashboard: {
    energy: { cost_per_kwh: 0.1, currency: "USD" },
    auth: { password: { __secret__: true } },
  },
  future: { keep: [1, 2] },
  _editable_keys: ["xvb.enabled", "dashboard.energy.cost_per_kwh"],
};

for (const theme of ["light", "dark"]) {
  test(`Earnings payouts, unavailable estimates and visual proof in ${theme}`, async ({
    page,
    ui,
  }, info) => {
    await page.addInitScript((value) => localStorage.setItem("dashboardTheme", value), theme);
    ui.state.control_enabled = true;
    ui.state.earnings.confirmed = { enabled: false };
    ui.state.earnings.tari_reward = 50;
    ui.state.tari.active = true;
    ui.state.payouts = {
      monero: [{ x: 1735689600000, amount: 1234567890123 }],
      tari: [{ x: 1735776000000, amount: 2500000 }],
    };
    ui.state.xvb_history = [{ x: 1735776000000, donation_fraction: 0.14 }];
    await ui.openPreview("?page=earnings");
    const main = page.getByRole("main");
    await expect(main.getByRole("heading", { name: "Recorded payouts" })).toBeVisible();
    await expect(main.locator(".payout-list li").first()).toContainText("2.500000 XTM");
    await expect(main.locator(".payout-list li").last()).toContainText("1.234567890123 XMR");
    await expect(
      main.getByText(/Tracking may be incomplete: no view-only tracking/).first(),
    ).toBeVisible();
    await expect(main.getByText(/Return estimates are unavailable/)).toBeVisible();
    await expect(main.getByText("50 XTM", { exact: true })).toBeVisible();
    await expect(main.getByText(/14% routed to XvB/)).toBeVisible();
    await expect(main.getByRole("button")).toHaveCount(2);
    await expect(main.getByRole("textbox")).toHaveCount(0);
    await expect(main.getByRole("tab")).toHaveCount(0);
    for (const width of [375, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(
        true,
      );
      await main.getByRole("button", { name: "Electricity price", exact: true }).focus();
      await expect(
        main.getByRole("button", { name: "Electricity price", exact: true }),
      ).toBeFocused();
      const path = info.outputPath(`earnings-${width}-${theme}.png`);
      await page.screenshot({ path, fullPage: true });
      await info.attach(`earnings-${width}-${theme}`, { path, contentType: "image/png" });
    }
    await main.getByRole("link", { name: "Advanced › Payout tracking" }).first().click();
    await expect(page.getByRole("dialog", { name: "Advanced", exact: true })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Payout", exact: true })).toBeVisible();
  });
}

for (const platform of ["appliance", "diy-login", "diy-readonly"]) {
  test(`Earnings control budget and Tari visibility on ${platform}`, async ({ page, ui }) => {
    ui.state.control_enabled = platform !== "diy-readonly";
    ui.state.os_update = platform === "appliance" ? { available: false } : null;
    ui.state.tari.active = false;
    await ui.openPreview("?page=earnings");
    const main = page.getByRole("main");
    await expect(main.getByRole("heading", { name: "Recorded payouts" })).toBeVisible();
    await expect(
      main.locator("button:visible, input:visible, select:visible, textarea:visible"),
    ).toHaveCount(platform === "diy-readonly" ? 0 : 2);
    expect(
      await main.locator("button:visible, input:visible, select:visible, textarea:visible").count(),
    ).toBeLessThanOrEqual(10);
    await expect(main.getByRole("heading", { name: "Tari solo mining" })).toHaveCount(0);
  });
}

test("Electricity price validates locally, previews exactly one change, and commits through a restart", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  ui.state.control_enabled = true;
  const requests = [];
  await page.route("**/api/config", (route) => route.fulfill({ json: config }));
  await page.route("**/api/control/preview", async (route) => {
    requests.push({
      kind: "preview",
      headers: route.request().headers(),
      body: route.request().postDataJSON(),
    });
    await route.fulfill({
      json: {
        id: "earnings-1",
        status: "previewed",
        destructive: true,
        changes: [
          { flag: "CONFIRM", msg: "Electricity price changes; affected services restart." },
        ],
      },
    });
  });
  await page.route("**/api/control/commit", async (route) => {
    requests.push({
      kind: "commit",
      headers: route.request().headers(),
      body: route.request().postDataJSON(),
    });
    await route.fulfill({ status: 502, body: "Restarting" });
  });
  await page.route("**/api/control/result?**", (route) =>
    route.fulfill({ json: { status: "applied" } }),
  );
  await ui.openPreview("?page=earnings");
  await page.getByRole("button", { name: "Electricity price", exact: true }).click();
  const edit = page.getByRole("dialog", { name: "Electricity price", exact: true });
  const input = edit.getByLabel("Electricity price (USD per kWh)");
  await expect(input).toHaveValue("0.1");
  await input.fill("-1");
  await expect(edit.getByRole("alert")).toContainText("zero or more");
  await expect(edit.getByRole("button", { name: "Review changes", exact: true })).toBeDisabled();
  expect(requests).toHaveLength(0);
  await input.fill("0.25");
  await edit.getByRole("button", { name: "Review changes", exact: true }).click();
  const review = page.getByRole("dialog", { name: "Review changes", exact: true });
  await expect(review.getByText(/affected services restart/)).toBeVisible();
  await expect(review.getByRole("button", { name: "Confirm & apply" })).toBeDisabled();
  await review.getByLabel(/Type APPLY to confirm/).fill("APPLY");
  await review.getByRole("button", { name: "Confirm & apply" }).click();
  await page.clock.fastForward(2000);
  await expect(page.getByText("Changes applied.", { exact: true })).toBeVisible();
  expect(requests).toHaveLength(2);
  expect(requests[0].body).toEqual({
    config: {
      ...config,
      _editable_keys: undefined,
      dashboard: { ...config.dashboard, energy: { cost_per_kwh: 0.25, currency: "USD" } },
    },
  });
  expect(requests[0].headers["x-pithead-control"]).toBe("1");
  expect(requests[1].headers["x-pithead-control"]).toBe("1");
  expect(requests[1].body).toEqual({ id: "earnings-1", confirm: "APPLY" });
});

test("XvB uses current host state, cancel never commits, and session expiry removes drafts", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  ui.state.control_enabled = true;
  let commits = 0;
  await page.route("**/api/config", (route) => route.fulfill({ json: config }));
  await page.route("**/api/control/preview", (route) =>
    route.fulfill({
      json: { id: "earnings-2", status: "previewed", changes: [{ msg: "Enable the XvB bonus." }] },
    }),
  );
  await page.route("**/api/control/commit", (route) => {
    commits++;
    return route.fulfill({ json: { status: "applied" } });
  });
  await ui.openPreview("?page=earnings");
  await page.getByRole("button", { name: "Join the XvB bonus", exact: true }).click();
  const edit = page.getByRole("dialog", { name: "Join the XvB bonus", exact: true });
  await expect(edit.getByRole("checkbox")).not.toBeChecked();
  await edit.getByRole("checkbox").check();
  await edit.getByRole("button", { name: "Review changes", exact: true }).click();
  await page
    .getByRole("dialog", { name: "Review changes", exact: true })
    .getByRole("button", { name: "Cancel", exact: true })
    .click();
  expect(commits).toBe(0);
  await page.getByRole("button", { name: "Join the XvB bonus", exact: true }).click();
  await expect(edit.getByRole("checkbox")).not.toBeChecked();
  await edit.getByRole("checkbox").check();
  await page.route("**/api/state?**", (route) => route.fulfill({ status: 401, body: "Expired" }));
  await page.clock.fastForward(30000);
  await expect(page.getByText("Session expired. Sign in again to reconnect.")).toBeVisible();
  await expect(edit).toHaveCount(0);
  await expect(page.getByRole("main").getByRole("button")).toHaveCount(0);
  expect(commits).toBe(0);
});
