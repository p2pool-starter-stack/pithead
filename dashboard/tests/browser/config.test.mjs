import { expect, test } from "./fixtures.mjs";

const CONFIG = {
  p2pool: { pool: "mini" },
  dashboard: { auth: { password: { __secret__: true } } },
  _core_keys: ["p2pool.pool"],
  _editable_keys: ["p2pool.pool", "dashboard.auth.password"],
};

const mount = (ui) =>
  ui.mount(`
import { ConfigView } from '/static/config/configview.mjs';
render(html\`<\${ConfigView} />\`, document.getElementById('fixture'));
`);

test("edits, previews, confirms, and commits the exact config through a restart", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  const requests = [];
  let polls = 0;
  await page.route("**/api/config", (route) => route.fulfill({ json: CONFIG }));
  await page.route("**/api/control/preview", async (route) => {
    requests.push({
      kind: "preview",
      headers: route.request().headers(),
      body: route.request().postDataJSON(),
    });
    await route.fulfill({
      json: {
        id: "config-1",
        status: "previewed",
        destructive: true,
        changes: [{ flag: "CONFIRM", key: "p2pool.pool", msg: "Pool changes to main." }],
      },
    });
  });
  await page.route("**/api/control/commit", async (route) => {
    requests.push({
      kind: "commit",
      headers: route.request().headers(),
      body: route.request().postDataJSON(),
    });
    await route.fulfill({ status: 502, body: "restarting" });
  });
  await page.route("**/api/control/result?**", async (route) => {
    polls++;
    await route.fulfill({ json: { status: "applied" } });
  });

  await mount(ui);
  await page.getByRole("combobox", { name: /^p2pool\.pool/ }).selectOption("main");
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  const dialog = page.getByRole("dialog", { name: "Review changes" });
  await expect(dialog.getByText("Pool changes to main.")).toBeVisible();
  await dialog.getByLabel(/Type APPLY to confirm/).fill("APPLY");
  await dialog.getByRole("button", { name: "Confirm & apply" }).click();
  await expect(dialog.getByRole("button", { name: "Applying…" })).toBeDisabled();
  await page.clock.fastForward(2000);
  await expect(page.getByText(/Changes applied/)).toBeVisible();

  expect(polls).toBe(1);
  expect(requests).toHaveLength(2);
  expect(requests[0].headers["x-pithead-control"]).toBe("1");
  expect(requests[0].body.config).toEqual({
    p2pool: { pool: "main" },
    dashboard: { auth: { password: { __secret__: true } } },
  });
  expect(requests[1].headers["x-pithead-control"]).toBe("1");
  expect(requests[1].body).toEqual({ id: "config-1", confirm: "APPLY" });
});

test("cancelled preview returns to the editor without committing", async ({ page, ui }) => {
  let commits = 0;
  await page.route("**/api/config", (route) => route.fulfill({ json: CONFIG }));
  await page.route("**/api/control/preview", (route) =>
    route.fulfill({
      json: {
        id: "config-2",
        status: "previewed",
        changes: [{ flag: "SET", msg: "Pool changes to nano." }],
      },
    }),
  );
  await page.route("**/api/control/commit", (route) => {
    commits++;
    return route.fulfill({ json: { status: "applied" } });
  });

  await mount(ui);
  await page.getByRole("combobox", { name: /^p2pool\.pool/ }).selectOption("nano");
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  const dialog = page.getByRole("dialog", { name: "Review changes" });
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await expect(dialog).toBeHidden();
  await expect(page.getByRole("button", { name: "Save & preview changes" })).toBeEnabled();
  expect(commits).toBe(0);
});

// #3353: Discard edits must take the rejected candidate's preview error with it.
test("discarding a rejected preview leaves a clean form without the old error", async ({
  page,
  ui,
}) => {
  await page.route("**/api/config", (route) => route.fulfill({ json: CONFIG }));
  await page.route("**/api/control/preview", (route) =>
    route.fulfill({
      json: { id: "config-3", status: "rejected", error: "p2pool.pool is not a valid pool" },
    }),
  );

  await mount(ui);
  await page.getByRole("combobox", { name: /^p2pool\.pool/ }).selectOption("nano");
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await expect(page.getByText("p2pool.pool is not a valid pool")).toBeVisible();
  await page.getByRole("button", { name: "Discard edits" }).click();
  await expect(page.getByRole("button", { name: "Save & preview changes" })).toBeDisabled();
  await expect(page.getByText("p2pool.pool is not a valid pool")).toHaveCount(0);
});

test("the old rejected-preview error stays gone after discarding and changing view", async ({
  page,
  ui,
}) => {
  const rejected = "p2pool.pool is not a valid pool";
  await page.route("**/api/config", (route) => route.fulfill({ json: CONFIG }));
  await page.route("**/api/control/preview", (route) =>
    route.fulfill({ json: { id: "config-4", status: "rejected", error: rejected } }),
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
  await page.getByRole("combobox", { name: /^p2pool\.pool/ }).selectOption("nano");
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await expect(page.getByText(rejected)).toBeVisible();
  await page.getByRole("button", { name: "Discard edits", exact: true }).click();
  await expect(page.getByRole("button", { name: "Save & preview changes" })).toBeDisabled();
  await expect(page.getByText(rejected)).toHaveCount(0);
  for (const view of ["Simple", "Advanced"]) {
    await nav.getByRole("button", { name: view, exact: true }).click();
    await nav.getByRole("button", { name: /^Configuration/ }).click();
    await expect(page.getByRole("button", { name: "Save & preview changes" })).toBeDisabled();
    await expect(page.getByText(rejected)).toHaveCount(0);
  }
});

for (const [name, text, message] of [
  ["malformed JSON", "{not json", "Not valid JSON."],
  ["duplicate JSON keys", '{"p2pool":{"pool":"mini","pool":"main"}}', /duplicate key "pool"/],
]) {
  test(`${name} is refused before preview`, async ({ page, ui }) => {
    let previews = 0;
    await page.route("**/api/config", (route) => route.fulfill({ json: CONFIG }));
    await page.route("**/api/control/preview", (route) => {
      previews++;
      return route.fulfill({ json: {} });
    });

    await mount(ui);
    await page.getByText("Advanced", { exact: true }).click();
    await page.locator("textarea.worker-edit").fill(text);
    await expect(page.getByText(message)).toBeVisible();
    await expect(page.getByRole("button", { name: "Save & preview changes" })).toBeDisabled();
    expect(previews).toBe(0);
  });
}

test("an untouched masked password stays a sentinel in the preview payload", async ({
  page,
  ui,
}) => {
  let body;
  await page.route("**/api/config", (route) => route.fulfill({ json: CONFIG }));
  await page.route("**/api/control/preview", async (route) => {
    body = route.request().postDataJSON();
    await route.fulfill({
      json: {
        id: "config-3",
        status: "previewed",
        changes: [{ flag: "SET", msg: "Pool changed." }],
      },
    });
  });

  await mount(ui);
  const password = page.getByPlaceholder("set — leave blank to keep");
  await expect(password).toHaveValue("");
  await page.getByRole("combobox", { name: /^p2pool\.pool/ }).selectOption("main");
  await page.getByRole("button", { name: "Save & preview changes" }).click();
  await expect(page.getByRole("dialog", { name: "Review changes" })).toBeVisible();
  expect(body.config.dashboard.auth.password).toEqual({ __secret__: true });
});
