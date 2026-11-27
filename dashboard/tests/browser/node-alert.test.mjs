import { expect, test } from "./fixtures.mjs";

const ALERT = {
  title: "Monero node offline",
  reasons: ["0 outgoing peers for 12 min", "Tor clearnet egress has failed for 20 min"],
  heal: [
    "Tor auto-heal last action: Tor restart, 5 min ago (attempt 3 of 3).",
    "Tor auto-heal stopped after 3 attempts; no more automatic action this outage.",
  ],
};

test("the dashboard stays quiet while no node alert is active", async ({ page, ui }) => {
  await ui.open();
  await expect(page.getByRole("group", { name: "Dashboard view" })).toBeVisible();
  await expect(page.getByRole("alert").filter({ hasText: "Monero node offline" })).toHaveCount(0);
});

for (const theme of ["Light", "Dark"]) {
  test(`${theme} theme: the node alert names the outage and the auto-heal state`, async ({
    page,
    ui,
  }) => {
    ui.state.node_alert = ALERT;
    await ui.open();
    await page.getByRole("button", { name: theme, exact: true }).click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme.toLowerCase());
    const banner = page.getByRole("alert").filter({ hasText: "Monero node offline" });
    await expect(banner).toBeVisible();
    await expect(banner).toContainText("0 outgoing peers for 12 min");
    await expect(banner).toContainText("Tor clearnet egress has failed for 20 min");
    await expect(banner).toContainText("Tor auto-heal last action: Tor restart, 5 min ago");
    await expect(banner).toContainText("Tor auto-heal stopped after 3 attempts");
  });
}
