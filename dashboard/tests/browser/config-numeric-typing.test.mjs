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

const paneCost = async (page) =>
  JSON.parse(await page.locator(".config-view textarea").inputValue()).dashboard.energy
    .cost_per_kwh;
const openPane = (page) =>
  page
    .locator(".config-view summary")
    .filter({ hasText: "the configuration this page sends" })
    .click();
const setPane = async (page, cost) => {
  const editor = page.locator(".config-view textarea");
  const cfg = JSON.parse(await editor.inputValue());
  cfg.dashboard.energy.cost_per_kwh = cost;
  await editor.fill(JSON.stringify(cfg, null, 2));
};

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
  await openPane(page);
  await input.focus();
  await input.press("ControlOrMeta+a");
  await input.press("Backspace");
  await expect(input).toHaveValue("");
  expect(await paneCost(page)).toBe(0.17);
  await expect(input).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByRole("alert").filter({ hasText: "Not a valid number" })).toBeVisible();
  await input.pressSequentially("0.");
  expect(await paneCost(page)).toBe(0.17);
  await input.pressSequentially("5");
  await expect(input).toHaveValue("0.5");
  await expect(input).not.toHaveAttribute("aria-invalid", "true");
  expect(await paneCost(page)).toBe(0.5);
});

test("an invalid draft blocks Save and the candidate keeps its last number (#3350)", async ({
  page,
  ui,
}) => {
  const { input, previews } = await open(page, ui);
  await openPane(page);
  await input.fill("0.2");
  await input.press("ControlOrMeta+a");
  await input.press("Backspace");
  await expect(input).toHaveAttribute("aria-invalid", "true");
  expect(await paneCost(page)).toBe(0.2);
  await expect(page.getByRole("button", { name: "Save & preview changes" })).toBeDisabled();
  await input.fill("0.25");
  await save(page);
  await expect(page.getByRole("dialog", { name: "Review changes" })).toBeVisible();
  expect(previews).toHaveLength(1);
  expect(previews[0].config.dashboard.energy.cost_per_kwh).toBe(0.25);
  expect(await paneCost(page)).toBe(0.25);
});

test("a pasted value lands whole in the field, the pane and the preview (#3350)", async ({
  page,
  ui,
}) => {
  const { input, previews } = await open(page, ui);
  await openPane(page);
  await input.fill("0.1701");
  await expect(input).toHaveValue("0.1701");
  expect(await paneCost(page)).toBe(0.1701);
  await save(page);
  await expect(page.getByRole("dialog", { name: "Review changes" })).toBeVisible();
  expect(previews[0].config.dashboard.energy.cost_per_kwh).toBe(0.1701);
});

test("a pane edit overrides the field's draft, a same-value rewrite keeps it (#3350)", async ({
  page,
  ui,
}) => {
  const { input, previews } = await open(page, ui);
  await openPane(page);
  await input.fill("0.50");
  expect(await paneCost(page)).toBe(0.5);
  // Same number in another form: the typed text survives.
  await setPane(page, 0.5);
  await expect(input).toHaveValue("0.50");
  // A different number: the field follows the pane.
  await setPane(page, 0.9);
  await expect(input).toHaveValue("0.9");
  await save(page);
  await expect(page.getByRole("dialog", { name: "Review changes" })).toBeVisible();
  expect(previews[0].config.dashboard.energy.cost_per_kwh).toBe(0.9);
});

test("a pane edit leaves an invalid draft flagged and Save blocked (#3350)", async ({
  page,
  ui,
}) => {
  const { input } = await open(page, ui);
  await openPane(page);
  await input.fill("");
  await expect(input).toHaveAttribute("aria-invalid", "true");
  await setPane(page, 0.3);
  await expect(input).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByRole("button", { name: "Save & preview changes" })).toBeDisabled();
  await input.fill("0.4");
  await expect(input).not.toHaveAttribute("aria-invalid", "true");
  expect(await paneCost(page)).toBe(0.4);
});
