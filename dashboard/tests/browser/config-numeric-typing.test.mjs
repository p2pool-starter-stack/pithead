import { expect, test } from "./fixtures.mjs";

const CONFIG = {
  dashboard: { energy: { cost_per_kwh: 0.17, currency: "USD" } },
  _editable_keys: ["dashboard.energy.cost_per_kwh"],
};

async function open(page, ui) {
  const previews = [];
  await page.route("**/api/config", (route) => route.fulfill({ json: CONFIG }));
  await page.route("**/api/control/preview", async (route) => {
    previews.push(route.request().postDataJSON());
    await route.fulfill({ json: { id: "n", status: "previewed", changes: [{ msg: "changed" }] } });
  });
  await ui.mount(`
import { ConfigView } from '/static/config/configview.mjs';
render(html\`<\${ConfigView} />\`, document.getElementById('fixture'));
`);
  await page
    .locator(".config-view summary")
    .filter({ hasText: /^Energy$/ })
    .click();
  const input = page.locator('.config-view input[type="number"]');
  await expect(input).toBeVisible();
  return { input, previews };
}

const save = (page) => page.getByRole("button", { name: "Save & preview changes" }).click();

test("sequential typing keeps every digit and previews the number (#3350)", async ({
  page,
  ui,
}) => {
  const { input, previews } = await open(page, ui);
  await input.focus();
  await input.press("ControlOrMeta+a");
  await input.pressSequentially("0.1701");
  await expect(input).toHaveValue("0.1701");
  await expect(input).not.toHaveAttribute("aria-invalid", "true");
  await save(page);
  await expect(page.getByRole("dialog", { name: "Review changes" })).toBeVisible();
  expect(previews[0].config.dashboard.energy.cost_per_kwh).toBe(0.1701);
});

test("a partial value is flagged, not rewritten, and leaves the candidate unchanged (#3350)", async ({
  page,
  ui,
}) => {
  const { input } = await open(page, ui);
  await input.focus();
  await input.press("ControlOrMeta+a");
  await input.press("Backspace");
  await expect(input).toHaveValue("");
  await expect(input).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByRole("alert").filter({ hasText: "Not a valid number" })).toBeVisible();
  await input.pressSequentially("0.");
  await input.pressSequentially("5");
  await expect(input).toHaveValue("0.5");
  await expect(input).not.toHaveAttribute("aria-invalid", "true");
});
