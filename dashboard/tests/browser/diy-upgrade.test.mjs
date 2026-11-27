import { expect, test } from "./fixtures.mjs";

test.beforeEach(async ({ page, ui }) => {
  ui.state.control_enabled = true;
  ui.state.os_update = null;
  await page.route("**/api/miner-connection", (route) =>
    route.fulfill({ json: { url: "stratum+tcp://example.invalid:3333", password_set: false } }),
  );
});

test("DIY upgrade confirms the exact version, survives restart polling and reloads the completed dashboard", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  const writes = [];
  let polls = 0;
  await page.route("**/api/control/upgrade", (route) => {
    writes.push(route.request());
    return route.fulfill({ status: 202, json: { id: "diy-upgrade" } });
  });
  await page.route("**/api/control/result?id=diy-upgrade", (route) => {
    polls++;
    if (polls === 1) return route.fulfill({ status: 502 });
    if (polls === 2) return route.fulfill({ json: { status: "running" } });
    ui.state.update.available = false;
    return route.fulfill({
      json: { status: "upgraded", version: "v9.9.9", rollback: "synthetic-previous-release" },
    });
  });
  await ui.open();
  const opener = page.getByRole("button", { name: "Upgrade to v9.9.9", exact: true });
  await opener.click();
  const confirm = page.getByRole("dialog", { name: "Upgrade to v9.9.9", exact: true });
  const upgrade = confirm.getByRole("button", { name: "Upgrade", exact: true });
  await confirm.getByRole("textbox").fill("upgrade");
  await expect(upgrade).toBeDisabled();
  await confirm.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(confirm).toHaveCount(0);
  expect(writes).toHaveLength(0);
  await opener.click();
  await expect(confirm.getByRole("textbox")).toHaveValue("");
  await confirm.getByRole("textbox").fill("UPGRADE");
  await upgrade.click();
  const busy = page.getByRole("dialog", { name: "Upgrading to v9.9.9…", exact: true });
  await expect(busy).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(busy).toBeVisible();
  expect(writes).toHaveLength(1);
  expect(writes[0].method()).toBe("POST");
  expect(writes[0].postDataJSON()).toEqual({ version: "v9.9.9" });
  expect(writes[0].headers()["x-pithead-control"]).toBe("1");
  for (let i = 1; i <= 3; i++) {
    await page.clock.fastForward(2000);
    await expect.poll(() => polls).toBe(i);
    if (i < 3) await expect(busy).toBeVisible();
  }
  const done = page.getByRole("dialog", { name: "Upgraded to v9.9.9", exact: true });
  await expect(done.getByText("synthetic-previous-release", { exact: true })).toBeVisible();
  await done.getByRole("button", { name: "Reload the dashboard", exact: true }).click();
  await expect(page.getByRole("group", { name: "Dashboard view" })).toBeVisible();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(opener).toHaveCount(0);
  expect(writes).toHaveLength(1);
});

test("appliances never offer the DIY upgrade path and read-only dashboards offer neither control", async ({
  page,
  ui,
}) => {
  const writes = [];
  page.on("request", (request) => {
    if (request.method() !== "GET") writes.push(request.url());
  });
  ui.state.os_update = { step: "idle" };
  await ui.open();
  await expect(page.getByRole("button", { name: /^OS update/ })).toBeVisible();
  await expect(page.getByRole("button", { name: "Upgrade to v9.9.9", exact: true })).toHaveCount(0);
  ui.state.control_enabled = false;
  await page.reload();
  await expect(page.getByRole("group", { name: "Dashboard view" })).toBeVisible();
  await expect(page.getByRole("button", { name: /^OS update/ })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Upgrade to v9.9.9", exact: true })).toHaveCount(0);
  expect(writes).toEqual([]);
});
