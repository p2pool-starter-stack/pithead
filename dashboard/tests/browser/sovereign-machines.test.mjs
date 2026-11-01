import { rigFleet } from "../frontend/fixtures/rigs.mjs";
import { expect, test } from "./fixtures.mjs";

const json = (body) => ({
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

for (const theme of ["light", "dark"]) {
  test(`Machines renders 100 rigs, the connect card and the inspector in ${theme}`, async ({
    page,
    ui,
  }, info) => {
    await page.addInitScript((value) => localStorage.setItem("dashboardTheme", value), theme);
    ui.state.control_enabled = true;
    ui.state.os_update = {};
    ui.state.workers = rigFleet(100);
    ui.responses.set(
      "/api/miner-connection",
      json({
        url: "stratum+ssl://pithead.local:3333",
        password_set: true,
        password: "rig-secret",
        tls: true,
        fingerprint: "AB:CD:EF",
      }),
    );
    ui.responses.set(
      "/api/worker?name=rig-010&range=24h",
      json({
        name: "rig-010",
        found: true,
        status: "online",
        control_enabled: true,
        editable: true,
        writable_keys: ["DONATION"],
        last_applied: {},
        rig_config: { DONATION: 1 },
        rigforge: { version: "1.0.0" },
        rigforge_update: null,
        hashrate_history: { hashrate: [{ x: 1735689600000, y: 1370 }], markers: [] },
      }),
    );
    ui.responses.set(
      "/api/control/worker-upgrade-all",
      json({
        version: "v1.15.0",
        eligible: [{ name: "rig-001", running: "v0.9.0" }],
        skipped: [{ name: "rig-005", reason: "control API unreachable" }],
        run: null,
      }),
    );
    await page.clock.install();
    await page.setViewportSize({ width: 375, height: 800 });
    const started = Date.now();
    await ui.openPreview("?page=machines");
    const main = page.getByRole("main");
    const rows = main.locator(".rig-row");
    await expect(rows).toHaveCount(100);
    const renderMs = Date.now() - started;
    info.annotations.push({ type: "machines-100-rig-render-ms", description: String(renderMs) });
    expect(renderMs).toBeLessThan(10000);
    await expect(rows.first()).toHaveClass(/rig-attention/);
    await expect(rows.last()).not.toHaveClass(/rig-attention/);
    await expect(main.getByText("rig-secret", { exact: true })).toBeVisible();
    await expect(main.getByText("AB:CD:EF", { exact: true })).toBeVisible();
    await expect(main.getByRole("button", { name: "Copy rig settings" })).toBeVisible();
    await expect(main.getByRole("button", { name: "Also mine on this box" })).toBeVisible();
    await expect(main.getByRole("button", { name: /Reveal|Copy password/ })).toHaveCount(0);
    await main.getByRole("button", { name: "Update all rigs to v1.15.0" }).click();
    const review = page.getByRole("dialog", { name: "Update all rigs to v1.15.0" });
    await expect(review.getByText("rig-005: control API unreachable")).toBeVisible();
    await review.getByRole("button", { name: "Cancel" }).click();
    await expect(review).toHaveCount(0);
    await expect(main.getByRole("combobox")).toBeHidden();
    await expect(main.getByRole("searchbox")).toBeHidden();
    await expect(main.getByText("unmanaged").first()).toBeVisible();
    for (const width of [375, 768, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(
        true,
      );
      const path = info.outputPath(`machines-${width}-${theme}.png`);
      await page.screenshot({ path, fullPage: true });
      await info.attach(`machines-${width}-${theme}`, { path, contentType: "image/png" });
    }
    const rig = rows.filter({ hasText: "rig-010" });
    await rig.scrollIntoViewIfNeeded();
    const before = await page.evaluate(() => scrollY);
    expect(before).toBeGreaterThan(0);
    await rig.focus();
    await page.keyboard.press("Enter");
    const dialog = page.getByRole("dialog", { name: "rig-010" });
    await expect(dialog).toBeVisible();
    await expect(dialog.getByText("1.37 kH/s average")).toBeVisible();
    await expect(dialog.getByText("RigForge 1.0.0 · latest")).toBeVisible();
    await expect(dialog.getByRole("button", { name: /^(24h|1w|All)$/ })).toHaveCount(0);
    await expect(dialog.getByRole("button", { name: "Apply to rig" })).toBeHidden();
    await dialog.getByText("Advanced", { exact: true }).click();
    await expect(dialog.getByRole("button", { name: "Apply to rig" })).toBeVisible();
    ui.state.workers = [
      { name: "aaa-new", status: "online", h60: 5000, adopted: true },
      ...ui.state.workers,
    ];
    await page.clock.fastForward(30000);
    await expect(rows).toHaveCount(101);
    await page.keyboard.press("Escape");
    await expect(dialog).toHaveCount(0);
    await expect(rig).toBeFocused();
    expect(await page.evaluate(() => scrollY)).toBe(before);
    await main.locator(".list-advanced summary").click();
    await main.getByRole("searchbox", { name: "Find a rig" }).fill("rig-dup");
    await expect(rows).toHaveCount(10);
    await expect(main.getByText("10 of 101 rigs match.")).toBeVisible();
  });
}
