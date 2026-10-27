import { expect, test } from "./fixtures.mjs";

const width = Number(process.env.PITHEAD_SCREENSHOT_WIDTH ?? 390);
if (!Number.isSafeInteger(width) || width < 1) {
  throw new Error("PITHEAD_SCREENSHOT_WIDTH must be a positive integer");
}

test.use({ viewport: { width, height: 900 } });

for (const theme of ["dark", "light"]) {
  test(`capture dashboard viewport in ${theme} theme`, async ({ page, ui }, testInfo) => {
    await ui.open();
    await page
      .getByRole("group", { name: "Theme", exact: true })
      .getByRole("button", { name: theme === "dark" ? "Dark" : "Light", exact: true })
      .click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
    await expect(
      page
        .getByRole("table", { name: "Workers", exact: true })
        .getByRole("row", { name: /^rig-alpha/ }),
    ).toBeVisible();
    await expect(page.getByRole("img", { name: /^Hashrate chart:/ })).toBeVisible();
    await page.evaluate(() => document.fonts.ready);
    expect(await page.evaluate(() => window.innerWidth)).toBe(width);
    const screenshot = await page.screenshot({
      path: testInfo.outputPath(`dashboard-${width}-${theme}.png`),
      animations: "disabled",
      scale: "css",
    });
    expect(screenshot.subarray(1, 4).toString()).toBe("PNG");
    expect(screenshot.readUInt32BE(16)).toBe(width);
    expect(screenshot.readUInt32BE(20)).toBe(900);
    await testInfo.attach(`dashboard-${width}-${theme}`, {
      body: screenshot,
      contentType: "image/png",
    });
  });
}
