import { expect, test } from "./fixtures.mjs";

const mount = (ui, os = { step: "idle" }) =>
  ui.mount(`
import { OsUpdateControl } from '/static/system/osupdate.mjs';
render(html\`<\${OsUpdateControl} os=\${${JSON.stringify(os)}} enabled=\${true} />\`,
  document.getElementById('fixture'));
`);

test("one error Close dismisses the native dialog and restores focus to OS updates", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  await page.route("**/api/control/os-update", (route) =>
    route.fulfill({
      status: 202,
      json: { id: "fixture-check" },
    }),
  );
  await page.route("**/api/control/result?**", (route) =>
    route.fulfill({
      json: {
        status: "failed",
        error: "the latest release publishes no appliance OS bundle",
      },
    }),
  );
  await mount(ui);
  const trigger = page.getByRole("button", { name: "OS updates", exact: true });
  // Focus is the precondition; WebKit pointer/Tab focus depends on platform preferences.
  await trigger.focus();
  await expect(trigger).toBeFocused();
  await page.keyboard.press("Enter");
  const dialog = page.getByRole("dialog", { name: "System update" });
  await dialog.getByRole("button", { name: "Check now", exact: true }).click();
  await expect(dialog.getByText(/Asking the release server/)).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dialog).toBeVisible();
  await page.clock.fastForward(2000);
  await expect(
    dialog.getByText("the latest release publishes no appliance OS bundle"),
  ).toBeVisible();
  await dialog.getByRole("button", { name: "Close", exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await expect(trigger).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(dialog.getByRole("button", { name: "Check now" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
  await expect(trigger).toBeFocused();
});

test("staged reboot requires exact confirmation and Later erases it", async ({ page, ui }) => {
  const actions = [];
  await page.route("**/api/control/os-update", (route) => {
    actions.push(route.request().postDataJSON());
    return route.fulfill({ status: 202, json: { id: "unexpected" } });
  });
  await mount(ui, { step: "reboot-pending", version: "2.0.0" });
  const trigger = page.getByRole("button", { name: "Reboot to finish the update to v2.0.0" });
  await trigger.click();
  const dialog = page.getByRole("dialog", { name: "System update" });
  const confirm = dialog.getByLabel(/Type REBOOT to confirm/);
  const reboot = dialog.getByRole("button", { name: "Reboot now" });
  for (const value of ["", "reboot", "REBOOT "]) {
    await confirm.fill(value);
    await expect(reboot).toBeDisabled();
  }
  await confirm.fill("REBOOT");
  await expect(reboot).toBeEnabled();
  await dialog.getByRole("button", { name: "Later" }).click();
  await expect(dialog).toHaveCount(0);
  await trigger.click();
  await expect(confirm).toHaveValue("");
  await expect(reboot).toBeDisabled();
  expect(actions).toEqual([]);
});

test("a host refusal never offers installation or reboot", async ({ page, ui }) => {
  await page.route("**/api/control/os-update", (route) => route.fulfill({ status: 403 }));
  await mount(ui);
  await page.getByRole("button", { name: "OS updates", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "System update" });
  await dialog.getByRole("button", { name: "Check now" }).click();
  await expect(dialog.getByText("HTTP 403")).toBeVisible();
  await expect(dialog.getByRole("button", { name: /Install|Reboot|Retry/ })).toHaveCount(0);
  await dialog.getByRole("button", { name: "Close", exact: true }).click();
  await expect(dialog).toHaveCount(0);
});
