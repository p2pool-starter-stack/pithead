import { expect, test } from "./fixtures.mjs";

for (const theme of ["light", "dark"])
  test(`Maintenance power controls at phone width (${theme})`, async ({ page, ui }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await page.emulateMedia({ colorScheme: theme });
    ui.state.os_update = {};
    ui.state.control_enabled = true;
    let posted;
    await page.route("**/api/control/power", async (route) => {
      posted = route.request().postDataJSON();
      await route.fulfill({ status: 202, json: { id: "receipt" } });
    });
    await page.route("**/api/control/result?*", (route) =>
      route.fulfill({ json: { status: "shutting-down" } }),
    );
    await ui.openPreview("?advanced=maintenance");
    const drawer = page.getByRole("dialog", { name: "Advanced", exact: true });
    const power = drawer.getByRole("region", { name: "Appliance power" });
    await expect(power).toBeVisible();
    await power.getByRole("button", { name: "Power off", exact: true }).click();
    const submit = power.getByRole("button", { name: "Power off now", exact: true });
    await expect(submit).toBeDisabled();
    await power.getByRole("textbox", { name: "Type POWEROFF to confirm" }).fill("POWEROFF");
    await submit.click();
    await expect(power.getByRole("status")).toContainText("will not reconnect");
    expect(posted).toEqual({ action: "poweroff" });
    expect(await drawer.evaluate((node) => node.scrollWidth <= node.clientWidth)).toBe(true);
    await page.screenshot({ path: test.info().outputPath(`drawer-power-${theme}.png`) });
  });

test("DIY never offers appliance power in Maintenance", async ({ page, ui }) => {
  ui.state.os_update = null;
  ui.state.control_enabled = true;
  await ui.openPreview("?advanced=maintenance");
  await expect(page.getByRole("dialog", { name: "Advanced", exact: true })).toBeVisible();
  await expect(page.getByRole("region", { name: "Appliance power" })).toHaveCount(0);
});
