import assert from "node:assert/strict";
import { expect, test } from "./fixtures.mjs";

const config = {
  dashboard: { energy: { cost_per_kwh: 0.17 } },
  _editable_keys: ["dashboard.energy.cost_per_kwh"],
};

test("configuration drafts and invalid JSON survive every internal view; marker clears only on reset or applied save", async ({
  page,
  ui,
}) => {
  let reads = 0;
  let releasePreview;
  let delayedPreview = false;
  let commitStatus = "applied";
  let dialogs = 0;
  let previewed;
  page.on("dialog", async (dialog) => {
    dialogs++;
    await dialog.dismiss();
  });
  await page.route("**/api/config", (route) => {
    reads++;
    return route.fulfill({ json: config });
  });
  await page.route("**/api/control/preview", async (route) => {
    if (delayedPreview)
      await new Promise((resolve) => {
        releasePreview = resolve;
      });
    previewed = route.request().postDataJSON();
    await route.fulfill({
      json: { id: "draft-preview", status: "previewed", changes: [{ msg: "Energy cost changed" }] },
    });
  });
  await page.route("**/api/control/commit", (route) =>
    route.fulfill({
      json: { status: commitStatus, error: "fixture apply failure" },
    }),
  );
  ui.state.control_enabled = false;
  try {
    await ui.mount(`import { App } from '/static/app/components.mjs';
const state = ${JSON.stringify(ui.state)};
const ui = {view:'config',range:'all',series:{},avg:'10m',theme:'auto',hintDismissed:true};
const draw = () => render(html\`<\${App} state=\${state} connected=\${true} ui=\${ui}
  onView=\${mode => {ui.view = mode; draw();}} />\`, document.getElementById('fixture'));
draw();
`);
    const nav = page.getByRole("navigation", { name: "View" });
    const configButton = () => nav.getByRole("button", { name: /^Configuration/ });
    const marker = () =>
      nav.getByRole("button", { name: "Configuration — Unsaved changes", exact: true });
    const editor = page.locator(".config-view textarea");
    await page
      .locator(".config-view summary")
      .filter({ hasText: "the configuration this page sends" })
      .click();
    const original = await editor.inputValue();
    await page
      .locator(".config-view summary")
      .filter({ hasText: /^Energy$/ })
      .click();
    await page.locator('.config-view input[type="number"]').fill("0.18");
    await marker().waitFor();
    const valid = await editor.inputValue();
    assert.equal(JSON.parse(valid).dashboard.energy.cost_per_kwh, 0.18);
    for (const text of [valid, '{"dashboard":']) {
      await editor.fill(text);
      for (const view of ["Simple", "Advanced", "Backup"]) {
        await page.getByRole("button", { name: view, exact: true }).click();
        await marker().waitFor();
        assert.equal(await editor.isVisible(), false);
        await configButton().click();
        assert.equal(await editor.inputValue(), text);
        if (text !== valid)
          assert.equal(
            await page.getByRole("button", { name: "Save & preview changes" }).isEnabled(),
            false,
          );
      }
    }
    assert.equal(reads, 1, "navigation must not reload and overwrite the candidate");
    await page.getByRole("button", { name: "Discard edits", exact: true }).click();
    await marker().waitFor({ state: "detached" });
    assert.equal(await editor.inputValue(), original);
    await editor.fill(valid);
    delayedPreview = true;
    await page.getByRole("button", { name: "Save & preview changes" }).click();
    await page.getByRole("button", { name: "Previewing…", exact: true }).waitFor();
    await page.getByRole("button", { name: "Simple", exact: true }).click();
    await expect
      .poll(() => Boolean(releasePreview), {
        message: "preview request reaches the fixture",
      })
      .toBe(true);
    releasePreview();
    delayedPreview = false;
    await page
      .locator(".config-view button")
      .filter({ hasText: "Save & preview changes" })
      .waitFor({ state: "attached" });
    await nav.getByRole("button", { name: "Advanced", exact: true }).click();
    assert.equal(await page.getByRole("dialog").count(), 0);
    await configButton().click();
    await page.getByRole("dialog", { name: "Review changes" }).waitFor();
    await marker().waitFor(); // Preview alone has not saved anything.
    await page.getByRole("button", { name: "Cancel", exact: true }).click();
    await marker().waitFor();
    commitStatus = "failed";
    await page.getByRole("button", { name: "Save & preview changes" }).click();
    await page.getByRole("button", { name: "Confirm & apply", exact: true }).click();
    await page.getByRole("button", { name: "Back to the form", exact: true }).waitFor();
    await marker().waitFor();
    await page.getByRole("button", { name: "Back to the form", exact: true }).click();
    await page.locator(".config-view").waitFor();
    await marker().waitFor(); // #3287: a failed apply keeps the rejected draft for correction.
    assert.equal(await editor.inputValue(), valid);
    // Correct the rejected draft in place and retry.
    await page
      .locator(".config-view summary")
      .filter({ hasText: "the configuration this page sends" })
      .click();
    const corrected = valid.replace("0.18", "0.19");
    await editor.fill(corrected);
    commitStatus = "applied";
    await page.getByRole("button", { name: "Save & preview changes" }).click();
    await page.getByRole("button", { name: "Confirm & apply", exact: true }).click();
    await page
      .getByText("Changes applied — only the affected containers were recreated.")
      .waitFor();
    await marker().waitFor({ state: "detached" });
    assert.equal(previewed.config.dashboard.energy.cost_per_kwh, 0.19);
    // The explicit discard replaces a rejected draft with the host configuration.
    await page.getByRole("button", { name: "Back to the form", exact: true }).click();
    await page
      .locator(".config-view summary")
      .filter({ hasText: "the configuration this page sends" })
      .click();
    await editor.fill(valid);
    commitStatus = "failed";
    await page.getByRole("button", { name: "Save & preview changes" }).click();
    await page.getByRole("button", { name: "Confirm & apply", exact: true }).click();
    await page
      .getByRole("button", { name: "Discard draft and reload from host", exact: true })
      .click();
    await marker().waitFor({ state: "detached" });
    assert.equal(await editor.inputValue(), original);
    assert.equal(dialogs, 0, "view navigation must not ask for discard confirmation");
  } finally {
    releasePreview?.();
  }
});

test("a failed commit request returns to the retained draft; only the explicit discard reloads the host copy", async ({
  page,
  ui,
}) => {
  let reads = 0;
  let dialogs = 0;
  page.on("dialog", async (dialog) => {
    dialogs++;
    await dialog.dismiss();
  });
  await page.route("**/api/config", (route) => {
    reads++;
    return route.fulfill({ json: config });
  });
  await page.route("**/api/control/preview", (route) =>
    route.fulfill({
      json: { id: "draft-preview", status: "previewed", changes: [{ msg: "Energy cost changed" }] },
    }),
  );
  await page.route("**/api/control/commit", (route) =>
    route.fulfill({ status: 500, body: "boom" }),
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
  const open = () =>
    page
      .locator(".config-view summary")
      .filter({ hasText: "the configuration this page sends" })
      .click();
  await open();
  const original = await editor.inputValue();
  await page
    .locator(".config-view summary")
    .filter({ hasText: /^Energy$/ })
    .click();
  await page.locator('.config-view input[type="number"]').fill("0.18");
  await marker().waitFor();
  const valid = await editor.inputValue();
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await page.getByRole("button", { name: "Confirm & apply", exact: true }).click();
  await page.getByText("HTTP 500").waitFor();
  assert.equal(await page.getByRole("button", { name: "Reload", exact: true }).count(), 0);
  await page.getByRole("button", { name: "Back to the form", exact: true }).click();
  await marker().waitFor();
  await open();
  assert.equal(await editor.inputValue(), valid);
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await page.getByRole("button", { name: "Confirm & apply", exact: true }).click();
  await page
    .getByRole("button", { name: "Discard draft and reload from host", exact: true })
    .click();
  await marker().waitFor({ state: "detached" });
  await open();
  assert.equal(await editor.inputValue(), original);
  assert.equal(reads, 2);
  assert.equal(dialogs, 0, "discarding must not ask for confirmation");
});
