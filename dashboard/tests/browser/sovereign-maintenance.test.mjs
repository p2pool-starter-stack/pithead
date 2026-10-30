import { expect, test } from "./fixtures.mjs";

for (const theme of ["light", "dark"]) {
  test(`maintenance retains reports and reviews downloads in ${theme}`, async ({
    page,
    ui,
  }, info) => {
    await page.addInitScript((value) => localStorage.setItem("dashboardTheme", value), theme);
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
      return route.fulfill({
        status: 200,
        contentType: "application/gzip",
        body: "fixture archive",
      });
    });
    await ui.openPreview("?page=overview&advanced=maintenance");
    await page.getByRole("button", { name: "Run health check" }).click();
    await expect(page.getByText(/Waiting for the host/)).toBeVisible();
    await page.clock.runFor(2000);
    await expect(page.getByText("1 failing, 0 warning, 1 ok")).toBeVisible();
    const service = page.getByText("monerod", { exact: true });
    await service.focus();
    await page.keyboard.press("Enter");
    await expect(page.getByText("monerod is not answering", { exact: true })).toBeVisible();
    await expect(
      page.getByText("Report time: 1970-01-01T00:01:40.000Z", { exact: true }),
    ).toBeVisible();
    await page.getByRole("link", { name: "Inspect", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Configured topology" })).toBeVisible();
    await page.getByRole("link", { name: "Maintenance", exact: true }).click();
    await expect(page.getByText("1 failing, 0 warning, 1 ok")).toBeVisible();
    await page.getByRole("button", { name: "Prepare support bundle" }).click();
    await expect(page.getByText(/Waiting for the host/)).toBeVisible();
    await page.clock.runFor(2000);
    const download = page.getByRole("button", { name: "Download reviewed bundle" });
    await expect(download).toBeDisabled();
    expect(downloads).toBe(0);
    await page.getByText("Review collected reports", { exact: true }).click();
    await expect(page.locator("pre.review")).toContainText("[redacted].onion");
    await page.getByLabel("I reviewed the identifiers in these reports.").check();
    const [file] = await Promise.all([page.waitForEvent("download"), download.click()]);
    expect(file.suggestedFilename()).toBe("pithead-browser-support.tar.gz");
    await expect.poll(() => downloads).toBe(1);
    for (const width of [1280, 375]) {
      await page.setViewportSize({ width, height: 900 });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(
        true,
      );
      await page.screenshot({
        path: info.outputPath(`drawer-maintenance-${theme}-${width}.png`),
        fullPage: true,
      });
      await page.getByRole("heading", { name: "Server health", exact: true }).scrollIntoViewIfNeeded();
      await page.screenshot({ path: info.outputPath(`drawer-server-health-${theme}-${width}.png`), fullPage: true });
      await page.getByRole("link", { name: "Inspect", exact: true }).click();
      await expect(page.getByRole("heading", { name: "Configured topology" })).toBeVisible();
      await page.getByLabel("Show the internal mesh").check();
      expect(await page.evaluate(() => localStorage.getItem("dashboardTopoMesh"))).toBe("1");
      await page.getByRole("button", { name: "monerod", exact: true }).click();
      await expect(page.getByRole("region", { name: "Service inspector" }).getByRole("link", { name: "Node and network settings" })).toHaveAttribute("href", "?page=settings&advanced=node-and-network");
      await page.screenshot({
        path: info.outputPath(`drawer-inspect-${theme}-${width}.png`),
        fullPage: true,
      });
      await page.getByText("Network reward", { exact: true }).scrollIntoViewIfNeeded();
      await page.screenshot({ path: info.outputPath(`drawer-statistics-${theme}-${width}.png`), fullPage: true });
      await page.getByRole("link", { name: "Maintenance", exact: true }).click();
    }
    await expect(page.getByRole("button", { name: /Restart|Reboot|Power off/ })).toHaveCount(0);
  });
}

for (const [name, result, message] of [
  [
    "failed",
    { status: "failed", error: "Host refused the health check" },
    "Host refused the health check",
  ],
  ["missing", { status: "applied" }, "The host returned no report."],
  ["empty", { status: "applied", doctor: { checks: [] } }, "No checks were reported."],
]) {
  test(`maintenance shows a ${name} health report honestly`, async ({ page, ui }) => {
    await page.clock.install();
    ui.state.control_enabled = true;
    await page.route("**/api/control/diag-doctor", (route) =>
      route.fulfill({ status: 202, json: { id: "health" } }),
    );
    await page.route("**/api/control/result?**", (route) => route.fulfill({ json: result }));
    await ui.openPreview("?advanced=maintenance");
    await page.getByRole("button", { name: "Run health check" }).click();
    await expect(page.getByText(/Waiting for the host/)).toBeVisible();
    await page.clock.runFor(2000);
    await expect(page.getByText(message, { exact: true })).toBeVisible();
    await expect(page.getByRole("button", { name: "Run health check" })).toBeEnabled();
  });
}

test("a long health request remains queued or running and a wait timeout is not a host failure", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  ui.state.control_enabled = true;
  await page.route("**/api/control/diag-doctor", (route) =>
    route.fulfill({ status: 202, json: { id: "health" } }),
  );
  let polls = 0;
  await page.route("**/api/control/result?**", (route) => {
    polls++;
    return route.fulfill({ status: 202, json: { status: "pending" } });
  });
  await ui.openPreview("?advanced=maintenance");
  const run = page.getByRole("button", { name: "Run health check" });
  await run.click();
  await expect(run).toBeDisabled();
  for (let poll = 1; poll <= 40; poll++) {
    await page.clock.runFor(2000);
    await expect.poll(() => polls).toBe(poll);
  }
  await expect(page.getByRole("alert")).toContainText("may still be queued or running");
  await expect(page.getByRole("region", { name: "Health report" })).toHaveCount(0);
});

test("a refused mesh preference save stays usable for this visit", async ({ page, ui }) => {
  await page.addInitScript(() => {
    Storage.prototype.setItem = () => { throw new Error("storage refused"); };
  });
  await ui.openPreview("?advanced=inspect");
  const mesh = page.getByLabel("Show the internal mesh");
  await mesh.check();
  await expect(mesh).toBeChecked();
  await expect(page.getByText("The browser could not save the mesh preference. It applies only to this visit.", { exact: true })).toBeVisible();
});
