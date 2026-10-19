import { expect, test } from "./fixtures.mjs";

const config = {
  dashboard: { energy: { cost_per_kwh: 0.17 } },
  _editable_keys: ["dashboard.energy.cost_per_kwh"],
};

test("configuration drafts, the review dialog and the backup dialog follow the synchronization screen", async ({
  page,
  ui,
}) => {
  let reads = 0;
  await page.route("**/api/config", (route) => {
    reads++;
    return route.fulfill({ json: config });
  });
  await page.route("**/api/control/preview", (route) =>
    route.fulfill({
      json: { id: "sync-preview", status: "previewed", changes: [{ msg: "Energy cost changed" }] },
    }),
  );
  ui.state.control_enabled = false;
  await ui.mount(`import { App } from '/static/app/components.mjs';
const state = ${JSON.stringify(ui.state)};
const ui = {view:'config',range:'all',series:{},avg:'10m',theme:'auto',hintDismissed:true};
const draw = () => render(html\`<\${App} state=\${state} connected=\${true} ui=\${ui}
  onView=\${mode => {ui.view = mode; draw();}} />\`, document.getElementById('fixture'));
window.setSyncing = (syncing) => { state.syncing = syncing; draw(); };
window.enableControl = () => { state.control_enabled = true; draw(); };
draw();
`);
  const setSyncing = (syncing) => page.evaluate((value) => window.setSyncing(value), syncing);
  const nav = page.getByRole("navigation", { name: "View" });
  const marker = () =>
    nav.getByRole("button", { name: "Configuration — Unsaved changes", exact: true });
  const editor = page.locator(".config-view textarea");
  const openDialogs = page.locator("dialog[open]");
  const stackCards = page.locator("#dashboard-view .grid-section-label");

  // The draft and its marker survive a sync screen without reloading the configuration.
  await page
    .locator(".config-view summary")
    .filter({ hasText: "the configuration this page sends" })
    .click();
  await page
    .locator(".config-view summary")
    .filter({ hasText: /^Energy$/ })
    .click();
  await page.locator('.config-view input[type="number"]').fill("0.18");
  await expect(marker()).toBeVisible();
  const draft = await editor.inputValue();
  await setSyncing(true);
  await expect(page.locator(".progress-text").first()).toBeVisible();
  await expect(editor).toBeHidden();
  await setSyncing(false);
  await expect(marker()).toBeVisible();
  await expect(editor).toHaveValue(draft);
  expect(reads, "a sync transition must not reload and overwrite the candidate").toBe(1);

  // An open review dialog closes behind the sync screen and returns with the draft intact.
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await expect(page.getByRole("dialog", { name: "Review changes" })).toBeVisible();
  await setSyncing(true);
  await expect(openDialogs).toHaveCount(0);
  await setSyncing(false);
  await expect(page.getByRole("dialog", { name: "Review changes" })).toBeVisible();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(marker()).toBeVisible();
  await expect(editor).toHaveValue(draft);

  // The stack cards are not rendered behind the sync screen.
  await page.getByRole("button", { name: "Simple", exact: true }).click();
  await expect(stackCards.first()).toBeAttached();
  await setSyncing(true);
  await expect(stackCards).toHaveCount(0);
  await setSyncing(false);
  await expect(stackCards.first()).toBeAttached();
  await expect(marker()).toBeVisible();

  // A backup confirmation dialog closes behind the sync screen too.
  await page.evaluate(() => window.enableControl());
  await page.getByRole("button", { name: "Backup", exact: true }).click();
  await page.getByRole("button", { name: "Back up now" }).click();
  await expect(page.getByRole("dialog", { name: "Create a backup" })).toBeVisible();
  await setSyncing(true);
  await expect(openDialogs).toHaveCount(0);
  await setSyncing(false);
  await expect(page.getByRole("dialog", { name: "Create a backup" })).toBeVisible();
});
