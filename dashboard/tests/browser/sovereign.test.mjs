import { expect, test } from "./fixtures.mjs";

test("page slots keep drafts mounted and guard navigation and reload", async ({ page, ui }) => {
  await ui.mount(`
import { initSovereign } from '/static/sovereign/main.mjs';
document.getElementById('fixture').id = 'app';
let dirty = false;
window.preview = initSovereign({ hasUnsavedChanges: () => dirty,
  renderPage: (page) => page === 'settings' ? html\`<label>Draft value <input onInput=\${() => { dirty = true; }} /></label>\` : null });
`);
  await page
    .getByRole("navigation", { name: "Main navigation" })
    .getByRole("link", { name: "Settings", exact: true })
    .click();
  await page.getByLabel("Draft value").fill("retained draft");
  page.once("dialog", (dialog) => dialog.dismiss());
  await page
    .getByRole("navigation", { name: "Main navigation" })
    .getByRole("link", { name: "Machines", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { level: 1, name: "Settings", exact: true }),
  ).toBeVisible();
  page.once("dialog", (dialog) => dialog.accept());
  await page
    .getByRole("navigation", { name: "Main navigation" })
    .getByRole("link", { name: "Machines", exact: true })
    .click();
  page.once("dialog", (dialog) => dialog.accept());
  await page
    .getByRole("navigation", { name: "Main navigation" })
    .getByRole("link", { name: "Settings", exact: true })
    .click();
  await expect(page.getByLabel("Draft value")).toHaveValue("retained draft");
  const historyLength = await page.evaluate(() => history.length);
  for (let attempt = 0; attempt < 2; attempt++) {
    page.once("dialog", (dialog) => dialog.dismiss());
    await page.evaluate(() => history.back());
    await expect.poll(() => new URL(page.url()).searchParams.get("page")).toBe("settings");
    expect(await page.evaluate(() => history.length)).toBe(historyLength);
  }
  expect(
    await page.evaluate(() => {
      const event = new Event("beforeunload", { cancelable: true });
      dispatchEvent(event);
      return event.defaultPrevented;
    }),
  ).toBe(true);
});

for (const required of [false, true]) {
  test(`loading Tari ${required ? "gates" : "does not hide"} Monero sync progress`, async ({
    page,
    ui,
  }) => {
    ui.state.syncing = true;
    ui.state.tari_gates_sync = required;
    ui.state.db_healthy = true;
    ui.state.monero.health.level = "unknown";
    ui.state.badges = [{ text: "Syncing...", variant: "warn" }];
    ui.state.sync = {
      monero: { state: "syncing", percent: 42, current: 42, target: 100, remaining: 58 },
      tari: { state: "loading", percent: 0, current: 0, target: 0, remaining: 0 },
    };
    await ui.openPreview();
    await expect(
      page.getByText(required ? "Syncing — progress unknown" : "Syncing 42%", { exact: true }),
    ).toBeVisible();
  });
}

for (const theme of ["light", "dark", "auto"]) {
  test(`lean shell navigation, native drawer and contrast in ${theme}`, async ({
    page,
    ui,
  }, info) => {
    await page.addInitScript((value) => localStorage.setItem("dashboardTheme", value), theme);
    await page.emulateMedia({ colorScheme: "dark" });
    ui.state.monero.health.level = "green";
    ui.state.profile = { name: "Balance" };
    await ui.openPreview("?range=week&tab=kept");
    await expect(page.getByText("Balance: Everything goes through Tor")).toBeVisible();
    await expect(page.getByRole("main")).toHaveCount(1);
    await expect(page.getByText("Connecting to Pithead…", { exact: true })).toHaveCount(0);
    for (const name of ["Machines", "Earnings", "Settings", "Overview"]) {
      await page
        .getByRole("navigation", { name: "Main navigation" })
        .getByRole("link", { name, exact: true })
        .click();
      await expect(page.getByRole("heading", { level: 1, name, exact: true })).toBeFocused();
      expect(new URL(page.url()).searchParams.get("range")).toBe("week");
      expect(new URL(page.url()).searchParams.get("tab")).toBe("kept");
      await expect(page.getByText("Healthy", { exact: true })).toBeVisible();
    }
    await page.goBack();
    await expect(
      page.getByRole("heading", { level: 1, name: "Settings", exact: true }),
    ).toBeVisible();
    await page.goForward();
    await expect(
      page.getByRole("heading", { level: 1, name: "Overview", exact: true }),
    ).toBeVisible();
    await page.getByRole("button", { name: "Advanced", exact: true }).click();
    const drawer = page.getByRole("dialog", { name: "Advanced", exact: true });
    await expect(drawer).toBeVisible();
    await drawer.getByRole("link", { name: "Appearance", exact: true }).click();
    await expect(drawer.getByRole("heading", { name: "Appearance", exact: true })).toBeFocused();
    await expect(drawer.getByRole("heading", { name: "Appearance", exact: true })).toHaveCSS(
      "font-weight",
      "850",
    );
    await expect(drawer.getByRole("combobox", { name: "Theme", exact: true })).toBeVisible();
    await drawer.getByLabel("Theme", { exact: true }).selectOption(theme);
    await page.keyboard.press("Escape");
    await expect(drawer).not.toBeVisible();
    await expect(page.getByRole("button", { name: "Advanced", exact: true })).toBeFocused();
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme);

    for (const width of [1280, 375]) {
      await page.setViewportSize({ width, height: 900 });
      const navigation = page.getByRole("navigation", { name: "Main navigation" });
      const opener = navigation.getByRole("button", { name: "Advanced", exact: true });
      const sidebar = page.getByRole("complementary", { name: "Stack navigation" });
      if (width === 1280) {
        expect((await sidebar.boundingBox()).width).toBe(232);
        const lastPage = await navigation
          .getByRole("link", { name: "Settings", exact: true })
          .boundingBox();
        const update = await page
          .getByRole("link", { name: "Update available", exact: true })
          .boundingBox();
        expect(update.y).toBeGreaterThan(lastPage.y);
        expect((await opener.boundingBox()).y).toBeGreaterThan(update.y);
      } else {
        const links = await navigation.getByRole("link").all();
        expect(links).toHaveLength(4);
        const bar = await navigation.boundingBox();
        expect(bar.y + bar.height).toBe(900);
        for (const link of links)
          expect((await link.boundingBox()).y).toBeCloseTo((await opener.boundingBox()).y, 0);
      }
      const palette = await page.evaluate(() => {
        const root = getComputedStyle(document.documentElement);
        const heading = getComputedStyle(document.querySelector("h1"));
        return {
          background: root.getPropertyValue("--bg").trim(),
          card: root.getPropertyValue("--card").trim(),
          accent: root.getPropertyValue("--accent").trim(),
          font: heading.fontFamily,
          weight: heading.fontWeight,
        };
      });
      expect(palette.background).toBe(theme === "light" ? "#faf7f0" : "#11100e");
      expect(palette.card).toBe(theme === "light" ? "#ffffff" : "#1b1916");
      expect(palette.accent).toBe(theme === "light" ? "#b9461a" : "#ff8c52");
      expect(palette.font).toContain("system-ui");
      expect(Number(palette.weight)).toBeGreaterThanOrEqual(800);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(
        true,
      );
      await page.screenshot({
        path: info.outputPath(`shell-${theme}-${width}.png`),
        fullPage: true,
      });
      await page.getByRole("button", { name: "Advanced", exact: true }).click();
      await drawer.getByRole("link", { name: "Appearance", exact: true }).click();
      await page.screenshot({
        path: info.outputPath(`drawer-${theme}-${width}.png`),
        fullPage: true,
      });
      await page.keyboard.press("Escape");
    }
    await page.getByRole("button", { name: "Advanced", exact: true }).click();
    await drawer.getByRole("link", { name: "Appearance", exact: true }).click();
    const failures = await page.evaluate(() => {
      const rgb = (text) =>
        text
          .match(/[\d.]+/g)
          ?.slice(0, 3)
          .map(Number);
      const luminance = (values) =>
        values
          .map((v) => v / 255)
          .map((v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4))
          .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
      const bad = [];
      for (const element of document.querySelectorAll(
        "a, button, input, select, textarea, label, summary, span, p, small, h1, h2, h3",
      )) {
        if (
          !element.getClientRects().length ||
          !(element.textContent.trim() || element.getAttribute("placeholder"))
        )
          continue;
        const placeholder = element.matches("input[placeholder]") && !element.value;
        const style = getComputedStyle(element, placeholder ? "::placeholder" : null);
        let parent = element;
        while (
          parent.parentElement &&
          getComputedStyle(parent).backgroundColor === "rgba(0, 0, 0, 0)"
        )
          parent = parent.parentElement;
        const fg = rgb(style.color),
          bg = rgb(getComputedStyle(parent).backgroundColor);
        if (!fg || !bg) {
          bad.push("missing computed color");
          continue;
        }
        const a = luminance(fg),
          b = luminance(bg);
        const ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
        const large =
          parseFloat(style.fontSize) >= 24 ||
          (parseFloat(style.fontSize) >= 18.66 && Number(style.fontWeight) >= 700);
        if (ratio < (large ? 3 : 4.5)) bad.push(`${element.tagName}: ${ratio.toFixed(2)}`);
      }
      return bad;
    });
    expect(failures).toEqual([]);
  });
}

test("polling failure and expired session keep the snapshot and retry recovers", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  ui.state.last_update = "retained sample";
  await ui.openPreview("?page=machines");
  await expect(page.getByText("Last snapshot: retained sample", { exact: true })).toBeVisible();
  await page.route("**/api/state?**", (route) => route.fulfill({ status: 401 }));
  await page.clock.fastForward(30000);
  await expect(page.getByText("Session expired. Sign in again to reconnect.")).toBeVisible();
  await expect(page.getByText("Last snapshot: retained sample · stale")).toBeVisible();
  await page.unroute("**/api/state?**");
  await page.getByRole("button", { name: "Retry connection" }).click();
  await expect(page.getByText("Session expired. Sign in again to reconnect.")).not.toBeVisible();
  await expect(page.getByRole("heading", { name: "Machines", exact: true })).toBeVisible();
});

test("shell leaves maintenance actions with their owning page", async ({ page, ui }) => {
  await ui.openPreview("?page=overview&advanced=maintenance");
  await expect(page.getByRole("dialog", { name: "Advanced", exact: true })).toBeVisible();
  await expect(
    page.getByText(
      "This section is being built for the new interface. Continue using the current dashboard until cutover.",
    ),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: /Run health check|Prepare support bundle/ }),
  ).toHaveCount(0);
});

for (const [query, pageName, section] of [
  ["?view=config&range=week&tab=kept", "Settings", "configuration-json"],
  ["?view=advanced&range=week&tab=kept", "Overview", "inspect"],
  ["?view=backup&range=week&tab=kept", "Settings", "backup"],
  ["?advanced=appearance&range=week&tab=kept", "Overview", "appearance"],
  ["?page=earnings&range=week&tab=kept", "Earnings", null],
  ["?range=week&tab=kept", "Machines", null],
]) {
  test(`saved page respects the explicit route ${query}`, async ({ page, ui }) => {
    await page.addInitScript(() => localStorage.setItem("pitheadPage", "machines"));
    await ui.openPreview(query);
    const url = new URL(page.url());
    expect(url.searchParams.get("page")).toBe(pageName.toLowerCase());
    expect(url.searchParams.get("advanced")).toBe(section);
    expect(url.searchParams.get("view")).toBeNull();
    expect(url.searchParams.get("range")).toBe("week");
    expect(url.searchParams.get("tab")).toBe("kept");
    if (section) {
      await expect(page.getByRole("dialog", { name: "Advanced", exact: true })).toBeVisible();
      await page.keyboard.press("Escape");
    }
    await expect(
      page.getByRole("heading", { name: pageName, exact: true, level: 1 }),
    ).toBeVisible();
  });
}

test("an APT install names the apt command beside the update link", async ({ page, ui }) => {
  ui.state.update = { available: true, latest: "v9.9.9", url: "https://example.invalid/rel" };
  ui.state.apt_update_command = "sudo apt update && sudo apt upgrade";
  await ui.openPreview("?page=machines");
  await expect(page.getByRole("link", { name: "Update available", exact: true })).toBeVisible();
  await expect(page.getByText("Update with sudo apt update && sudo apt upgrade")).toBeVisible();
});
