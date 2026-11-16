import { readFile } from "node:fs/promises";

import { manifestZip, readZip } from "../frontend/helpers/zip.mjs";
import { expect, test } from "./fixtures.mjs";

const mount = (ui) =>
  ui.mount(`
import { SupportBundlePanel } from '/static/system/supportbundle.mjs';
render(html\`<\${SupportBundlePanel} />\`, document.getElementById('fixture'));
`);

const ID = "33333333-3333-4333-8333-333333333333";
const NAME = "support-bundle-20261115T120000Z.zip";

async function fakeHost(page, { oldest, outcome }) {
  const posts = [];
  await page.route("**/api/control/support-bundle-range", async (route) => {
    await route.fulfill({ status: 202, json: { id: "range-1" } });
  });
  await page.route("**/api/control/support-bundle", async (route) => {
    posts.push(route.request().postDataJSON());
    await route.fulfill({ status: 202, json: { id: ID } });
  });
  await page.route("**/api/control/support-bundle-result?**", async (route) => {
    const id = new URL(route.request().url()).searchParams.get("id");
    if (id === "range-1") return route.fulfill({ json: { status: "applied", oldest } });
    const body = posts.at(-1);
    await route.fulfill({ json: outcome(body) });
  });
  await page.route("**/api/control/support-bundle-download?**", async (route) => {
    const { since, until } = posts.at(-1);
    await route.fulfill({
      body: manifestZip({ since, until, oldest }),
      headers: {
        "Content-Type": "application/zip",
        "Content-Disposition": `attachment; filename="${NAME}"`,
      },
    });
  });
  return posts;
}

const applied = (body) => ({
  status: "applied",
  archive: NAME,
  since: body.since,
  until: body.until,
  effective_since: body.since,
  effective_until: body.until,
  journal_short: false,
});

test("one click on a custom range collects and downloads a zip holding that window", async ({
  page,
  ui,
}) => {
  const oldest = "2020-01-01T00:00:00Z";
  const posts = await fakeHost(page, { oldest, outcome: applied });
  await mount(ui);
  await expect(
    page.getByText("Logs on this system reach back to 2020-01-01 00:00:00 UTC"),
  ).toBeVisible();

  await page.getByLabel("Time frame").selectOption("custom");
  await page.locator('input[name="since"]').fill("2026-11-15T09:00");
  await page.locator('input[name="until"]').fill("2026-11-15T11:00");
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export logs" }).click();
  const file = await download;

  expect(file.suggestedFilename()).toMatch(/^support-bundle-\d{8}T\d{6}Z\.zip$/);
  const body = posts[0];
  expect(Date.parse(body.since)).toBe(new Date("2026-11-15T09:00").getTime());
  expect(Date.parse(body.until)).toBe(new Date("2026-11-15T11:00").getTime());
  const files = readZip(await readFile(await file.path()));
  const manifest = JSON.parse(files["bundle/manifest.json"]);
  expect(manifest.window.requested).toEqual({ since: body.since, until: body.until });
  expect(manifest.window.effective).toEqual({ since: body.since, until: body.until });
  expect(files["bundle/journal/all.log"]).toContain("marker");
  await expect(page.getByText("Downloaded")).toBeVisible();
  await expect(page.getByText(NAME).first()).toBeVisible();
});

test("a preset sends its hours and a range past the oldest log is flagged first", async ({
  page,
  ui,
}) => {
  const oldest = new Date(Date.now() - 3 * 3600 * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
  const posts = await fakeHost(page, {
    oldest,
    outcome: (body) => ({
      ...applied({ since: oldest, until: oldest }),
      journal_short: !!body.hours,
    }),
  });
  await mount(ui);
  await expect(page.getByRole("note")).toContainText("The bundle will start there");
  await page.getByLabel("Time frame").selectOption("1");
  await expect(page.getByRole("note")).toHaveCount(0);
  await page.getByLabel("Time frame").selectOption("6");
  await expect(page.getByRole("note")).toBeVisible();
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export logs" }).click();
  await download;
  expect(posts[0]).toEqual({ hours: 6 });
  await expect(page.getByText("shorter than you asked")).toBeVisible();
});

test("an invalid range is refused with a clear message and sends nothing", async ({ page, ui }) => {
  const posts = await fakeHost(page, { oldest: null, outcome: applied });
  await mount(ui);
  await page.getByLabel("Time frame").selectOption("custom");
  await page.locator('input[name="since"]').fill("2026-11-15T11:00");
  await page.locator('input[name="until"]').fill("2026-11-15T09:00");
  await page.getByRole("button", { name: "Export logs" }).click();
  await expect(page.getByRole("alert")).toContainText("the start must be before the end");
  expect(posts).toEqual([]);
});

test("a host rate limit and a failed collect each show their own message", async ({ page, ui }) => {
  let mode = "rejected";
  await fakeHost(page, {
    oldest: null,
    outcome: () =>
      mode === "rejected"
        ? {
            status: "rejected",
            error:
              "a support bundle was collected less than a minute ago — wait for the download window, then retry.",
          }
        : {
            status: "failed",
            error: "the host could not collect a support bundle — nothing was written.",
          },
  });
  await mount(ui);
  const exportButton = page.getByRole("button", { name: "Export logs" });
  await exportButton.click();
  await expect(page.getByRole("alert")).toContainText("less than a minute ago");
  mode = "failed";
  await exportButton.click();
  await expect(page.getByRole("alert")).toContainText("could not collect a support bundle");
});

test("a collected bundle whose download is gone says the download is unavailable", async ({
  page,
  ui,
}) => {
  await fakeHost(page, { oldest: null, outcome: applied });
  await page.route("**/api/control/support-bundle-download?**", (route) =>
    route.fulfill({ status: 404, body: "gone" }),
  );
  await mount(ui);
  await page.getByRole("button", { name: "Export logs" }).click();
  await expect(page.getByRole("alert")).toContainText("download is unavailable (HTTP 404)");
});
