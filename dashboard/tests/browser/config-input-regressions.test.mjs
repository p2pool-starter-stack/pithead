import { expect, test } from "./fixtures.mjs";

const CONFIG = {
  dashboard: { energy: { cost_per_kwh: 0.17, currency: "USD" } },
  workers: { list: [] },
  notifications: { webhooks: [] },
  _editable_keys: ["dashboard.energy.cost_per_kwh"],
  _default_keys: ["workers.list", "notifications.webhooks"],
};

const mount = (ui) =>
  ui.mount(`
import { ConfigView } from '/static/config/configview.mjs';
render(html\`<\${ConfigView} />\`, document.getElementById('fixture'));
`);

async function capturePreview(page, ui) {
  let preview;
  await page.route("**/api/config", (route) => route.fulfill({ json: CONFIG }));
  await page.route("**/api/control/preview", async (route) => {
    preview = route.request().postDataJSON();
    await route.fulfill({
      json: { id: "config-input", status: "previewed", changes: [{ msg: "Energy changed" }] },
    });
  });
  await mount(ui);
  await page
    .locator(".config-view summary")
    .filter({ hasText: /^Energy$/ })
    .click();
  const input = page.locator('.config-view input[type="number"]');
  await expect(input).toBeVisible();
  return {
    input,
    preview: () => preview,
  };
}

test("a pasted decimal keeps every digit and previews the exact number (#3350 control)", async ({
  page,
  ui,
}) => {
  const fixture = await capturePreview(page, ui);
  await fixture.input.fill("0.1701");
  await expect(fixture.input).toHaveValue("0.1701");
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await expect(page.getByRole("dialog", { name: "Review changes" })).toBeVisible();
  expect(fixture.preview().config.dashboard.energy.cost_per_kwh).toBe(0.1701);
});

test("sequential keyboard entry keeps the trailing zero in the completed decimal (#3350)", async ({
  page,
  ui,
}) => {
  const fixture = await capturePreview(page, ui);
  await fixture.input.focus();
  await fixture.input.press("End");
  await fixture.input.press("0");
  await fixture.input.press("1");
  await expect(fixture.input).toHaveValue("0.1701");
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await expect(page.getByRole("dialog", { name: "Review changes" })).toBeVisible();
  expect(fixture.preview().config.dashboard.energy.cost_per_kwh).toBe(0.1701);
});

test("one scalar edit does not materialize untouched default arrays (#3355)", async ({
  page,
  ui,
}) => {
  const fixture = await capturePreview(page, ui);
  await fixture.input.fill("0.18");
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await expect(page.getByRole("dialog", { name: "Review changes" })).toBeVisible();
  expect(fixture.preview().config.dashboard.energy.cost_per_kwh).toBe(0.18);
  expect(fixture.preview().config.workers).toBeUndefined();
  expect(fixture.preview().config.notifications).toBeUndefined();
});
