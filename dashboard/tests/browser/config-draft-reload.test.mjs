import assert from "node:assert/strict";
import { expect, test } from "./fixtures.mjs";

const config = {
  dashboard: { energy: { cost_per_kwh: 0.17 } },
  _editable_keys: ["dashboard.energy.cost_per_kwh"],
};
const NOTE = "Your unsaved edits were restored after the page reloaded.";

test("an unsaved configuration draft survives a page reload; applied save and discard clear it", async ({
  page,
  ui,
}) => {
  await page.route("**/api/config", (route) => route.fulfill({ json: config }));
  await page.route("**/api/control/preview", (route) =>
    route.fulfill({
      json: { id: "draft-preview", status: "previewed", changes: [{ msg: "Energy cost changed" }] },
    }),
  );
  await page.route("**/api/control/commit", (route) =>
    route.fulfill({ json: { status: "applied" } }),
  );
  ui.state.control_enabled = false;
  await ui.mount(`import { App } from '/static/app/components.mjs';
const state = ${JSON.stringify(ui.state)};
const ui = {view:'config',range:'all',series:{},avg:'10m',theme:'auto',hintDismissed:true};
const draw = () => render(html\`<\${App} state=\${state} connected=\${true} ui=\${ui}
  onView=\${mode => {ui.view = mode; draw();}} />\`, document.getElementById('fixture'));
draw();
`);
  const nav = page.getByRole("navigation", { name: "View" });
  const marker = () =>
    nav.getByRole("button", { name: "Configuration — Unsaved changes", exact: true });
  const editor = page.locator(".config-view textarea");
  const stash = () => page.evaluate(() => sessionStorage.getItem("pitheadConfigDraft"));
  const cost = async () => JSON.parse(await editor.inputValue()).dashboard.energy.cost_per_kwh;
  const openPane = () =>
    page
      .locator(".config-view summary")
      .filter({ hasText: "the configuration this page sends" })
      .click();

  await editor.waitFor({ state: "attached" });
  await openPane();
  await page
    .locator(".config-view summary")
    .filter({ hasText: /^Energy$/ })
    .click();
  const original = await editor.inputValue();
  await page.locator('.config-view input[type="number"]').fill("0.18");
  await marker().waitFor();

  await page.reload();
  await marker().waitFor();
  await openPane();
  assert.equal(await cost(), 0.18);
  await page.getByText(NOTE).waitFor();

  await editor.fill('{"dashboard":');
  await page.reload();
  await marker().waitFor();
  await openPane();
  assert.equal(await editor.inputValue(), '{"dashboard":');
  await expect(page.locator(".config-view .status-bad")).toBeVisible();
  assert.equal(
    await page.getByRole("button", { name: "Save & preview changes" }).isEnabled(),
    false,
  );

  await page.getByRole("button", { name: "Discard edits", exact: true }).click();
  await marker().waitFor({ state: "detached" });
  assert.equal(await stash(), null);
  await page.reload();
  await editor.waitFor({ state: "attached" });
  await marker().waitFor({ state: "detached" });
  assert.equal(await editor.inputValue(), original);

  await openPane();
  await editor.fill(JSON.stringify({ dashboard: { energy: { cost_per_kwh: 0.19 } } }, null, 2));
  await marker().waitFor();
  assert.notEqual(await stash(), null);
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await page.getByRole("button", { name: "Confirm & apply", exact: true }).click();
  await page.getByText("Changes applied — only the affected containers were recreated.").waitFor();
  await marker().waitFor({ state: "detached" });
  assert.equal(await stash(), null);
  await page.reload();
  await editor.waitFor({ state: "attached" });
  await marker().waitFor({ state: "detached" });
  assert.equal(await editor.inputValue(), original);
  await expect(page.getByText(NOTE)).toHaveCount(0);
});
