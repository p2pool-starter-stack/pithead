import { expect, test } from "./fixtures.mjs";

function enableEarnings(ui) {
  Object.assign(ui.state.earnings, {
    available: true,
    p2pool_hr: 1000,
    p2pool_hr_str: "1.00 kH/s",
    coeff_day: 0.001,
    pool_difficulty: 1000,
    tari_available: true,
    tari_coeff_day: 0.002,
    tari_difficulty: 1000,
    tari_reward: 50,
    xvb_day: 0.5,
  });
  Object.assign(ui.state.energy, {
    available: true,
    total_watts: 1000,
    hs_per_watt: 1,
    incomplete: false,
    cost_per_kwh: 0.25,
    xmr_price: 100,
    tari_price: 10,
    currency: "USD",
  });
}

async function openAdvanced(page, ui) {
  await ui.open();
  await page
    .getByRole("group", { name: "Dashboard view" })
    .getByRole("button", { name: "Advanced", exact: true })
    .click();
}

test("earnings tabs expose ARIA state and share one hashrate input", async ({ page, ui }) => {
  enableEarnings(ui);
  await openAdvanced(page, ui);

  const tabs = page.getByRole("tablist", { name: "Earnings breakdown" });
  const monero = tabs.getByRole("tab", { name: "Monero" });
  const tari = tabs.getByRole("tab", { name: "Tari" });
  const xvb = tabs.getByRole("tab", { name: "XvB" });
  const energy = tabs.getByRole("tab", { name: "Energy" });
  await expect(monero).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#epanel-monero")).toBeVisible();
  await expect(page.locator("#epanel-tari")).toBeHidden();

  const hashrate = page.getByRole("textbox", { name: "Your P2Pool Hashrate" });
  await hashrate.fill("2 kH/s");
  await expect(page.locator("#epanel-monero tbody tr").first()).toContainText("2.0000 XMR");
  await tari.click();
  await expect(tari).toHaveAttribute("aria-selected", "true");
  await expect(monero).toHaveAttribute("aria-selected", "false");
  await expect(page.locator("#epanel-tari")).toBeVisible();
  await expect(page.locator("#epanel-tari tbody tr").first()).toContainText("4.0000 XTM");
  await expect(hashrate).toHaveValue("2 kH/s");
  await xvb.click();
  await expect(xvb).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#epanel-xvb")).toBeVisible();
  await energy.click();
  await expect(energy).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#epanel-energy")).toBeVisible();
  await expect(hashrate).toHaveValue("2 kH/s");
});

test("the selected earnings tab survives a full page reload", async ({ page, ui }) => {
  enableEarnings(ui);
  await openAdvanced(page, ui);
  const energy = page.getByRole("tab", { name: "Energy" });
  await energy.click();
  await expect(energy).toHaveAttribute("aria-selected", "true");

  await page.reload();
  await expect(page.getByRole("tab", { name: "Energy" })).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#epanel-energy")).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem("dashboardEarningsTab"))).toBe("energy");
});

test("Energy shows each revenue source once and disappears without fleet power", async ({
  page,
  ui,
}) => {
  enableEarnings(ui);
  await openAdvanced(page, ui);
  await page.getByRole("tab", { name: "Energy" }).click();
  const panel = page.locator("#epanel-energy");

  await expect(
    panel.getByRole("heading", { name: /P2Pool \+ Tari \+ XvB \(est\.\), after power/ }),
  ).toBeVisible();
  const headers = panel.locator("thead th");
  await expect(headers).toHaveText(["Row", "kWh", "Revenue (est.)", "Power Cost", "Net"]);
  const day = panel.getByRole("row", { name: /^Day / });
  await expect(day.getByRole("cell")).toHaveText(["24.0", "170.00", "6.00", "164.00"]);

  ui.state.energy.available = false;
  await page.reload();
  await expect(page.getByRole("tab", { name: "Energy" })).toHaveCount(0);
  await expect(page.locator("#epanel-energy")).toHaveCount(0);
  await expect(page.getByRole("tab", { name: "Monero" })).toHaveAttribute("aria-selected", "true");
});
