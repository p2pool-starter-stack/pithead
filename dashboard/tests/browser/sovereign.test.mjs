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

for (const theme of ["light", "dark", "auto"]) {
  test(`lean shell navigation, native drawer and contrast in ${theme}`, async ({
    page,
    ui,
  }, info) => {
    await page.addInitScript((value) => localStorage.setItem("dashboardTheme", value), theme);
    await page.emulateMedia({ colorScheme: "dark" });
    ui.state.monero.health.level = "ok";
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
    await drawer.getByLabel("Theme", { exact: true }).selectOption(theme);
    await page.keyboard.press("Escape");
    await expect(drawer).not.toBeVisible();
    await expect(page.getByRole("button", { name: "Advanced", exact: true })).toBeFocused();
    await expect(page.locator("html")).toHaveAttribute("data-theme", theme);

    for (const width of [1280, 375]) {
      await page.setViewportSize({ width, height: 900 });
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

test("maintenance retains its report across drawer navigation and reviews before downloading", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  ui.state.control_enabled = true;
  const id = "a1111111-1111-4111-8111-111111111111";
  const doctor = {
    summary: { fail: 1, warn: 0, ok: 1 },
    checks: [{ status: "fail", message: "monerod is not answering" }],
  };
  let kind;
  await page.route("**/api/control/diag-*", (route) => {
    kind = route.request().url().endsWith("diag-bundle") ? "bundle" : "health";
    return route.fulfill({ status: 202, json: { id } });
  });
  await page.route("**/api/control/result?**", (route) =>
    route.fulfill({
      json:
        kind === "health"
          ? { status: "applied", doctor, ts: 100 }
          : {
              id,
              status: "applied",
              kind: "diag-bundle",
              bundle: { doctor, logs: { tor: "[redacted].onion" } },
              ts: 200,
            },
    }),
  );
  let downloads = 0;
  await page.route("**/api/control/bundle-download", (route) => {
    downloads++;
    expect(route.request().headers()["x-pithead-control"]).toBe("1");
    expect(route.request().postDataJSON()).toEqual({ id, reviewed: true });
    return route.fulfill({ status: 200, contentType: "application/gzip", body: "fixture archive" });
  });
  await ui.openPreview("?page=overview&advanced=maintenance");
  await page.getByRole("button", { name: "Run health check" }).click();
  await expect(page.getByText(/Waiting for the host/)).toBeVisible();
  await page.clock.fastForward(2000);
  await expect(page.getByText("1 failing, 0 warning, 1 ok")).toBeVisible();
  await page.getByRole("link", { name: "Inspect", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Configured topology" })).toBeVisible();
  await page.getByRole("link", { name: "Maintenance", exact: true }).click();
  await expect(page.getByText("1 failing, 0 warning, 1 ok")).toBeVisible();
  await page.getByRole("button", { name: "Prepare support bundle" }).click();
  await page.clock.fastForward(2000);
  const download = page.getByRole("button", { name: "Download reviewed bundle" });
  await expect(download).toBeDisabled();
  expect(downloads).toBe(0);
  await page.getByText("Review collected reports", { exact: true }).click();
  await expect(page.locator("pre.review")).toContainText("[redacted].onion");
  await page.getByLabel("I reviewed the identifiers in these reports.").check();
  await download.click();
  await expect.poll(() => downloads).toBe(1);
  await page.setViewportSize({ width: 375, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await expect(page.getByRole("button", { name: /Restart|Reboot|Power off/ })).toHaveCount(0);
});
