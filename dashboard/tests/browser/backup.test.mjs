import { readFile } from "node:fs/promises";
import { expect, test } from "./fixtures.mjs";

const mount = (ui) =>
  ui.mount(`
import { BackupPanel } from '/static/system/backupview.mjs';
render(html\`<\${BackupPanel} enabled=\${true} />\`, document.getElementById('fixture'));
`);
const applied = (id) => ({
  status: "applied",
  passphrase: `synthetic-passphrase-${id}`,
  archive: `pithead-backup-${id}.tar.gz.enc`,
  contents: ["config.json", "the dashboard database"],
  ts: 1_000,
});

test("cancelling the confirmation sends no backup request", async ({ page, ui }) => {
  let posts = 0;
  await page.route("**/api/control/backup", (route) => {
    posts++;
    return route.fulfill({ status: 202, json: { id: "unused" } });
  });
  await mount(ui);

  const trigger = page.getByRole("button", { name: "Back up now" });
  await trigger.click();
  const dialog = page.getByRole("dialog", { name: "Create a backup" });
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await expect(dialog).toBeHidden();
  expect(posts).toBe(0);
});

test("successful backup downloads the kit and archive and clears the one-time secret", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  let post;
  await page.route("**/api/control/backup", async (route) => {
    post = route.request();
    await route.fulfill({ status: 202, json: { id: "success" } });
  });
  await page.route("**/api/control/result?**", (route) =>
    route.fulfill({ json: applied("success") }),
  );
  // WebKit interception does not emit native downloads; serve the attachment over HTTP.
  ui.responses.set("/api/control/backup-download?id=success", {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Disposition": 'attachment; filename="pithead-backup-success.tar.gz.enc"',
    },
    body: "synthetic encrypted archive bytes",
  });
  await mount(ui);

  await page.getByRole("button", { name: "Back up now" }).click();
  await page
    .getByRole("dialog", { name: "Create a backup" })
    .getByRole("button", { name: "Create backup" })
    .click();
  await page.clock.fastForward(2000);

  await expect(page.getByRole("heading", { name: "Backup created" })).toBeVisible();
  await expect(page.getByText("synthetic-passphrase-success", { exact: true })).toBeVisible();
  const kit = page.getByRole("link", { name: "Download kit (.txt)" });
  const kitText = decodeURIComponent((await kit.getAttribute("href")).split(",", 2)[1]);
  expect(kitText).toContain("Passphrase:  synthetic-passphrase-success");
  expect(kitText).toContain("Archive:     pithead-backup-success.tar.gz.enc");
  expect(kitText).toContain("- config.json");
  await expect(kit).toHaveAttribute("download", "pithead-backup-success-kit.txt");
  await expect(page.getByRole("link", { name: "Download archive" })).toHaveAttribute(
    "href",
    "/api/control/backup-download?id=success",
  );
  for (const [link, filename, contents] of [
    [kit, "pithead-backup-success-kit.txt", "synthetic-passphrase-success"],
    [
      page.getByRole("link", { name: "Download archive" }),
      "pithead-backup-success.tar.gz.enc",
      "synthetic encrypted archive bytes",
    ],
  ]) {
    const downloading = page.waitForEvent("download");
    await link.click();
    const download = await downloading;
    expect(await download.failure()).toBeNull();
    expect(download.suggestedFilename()).toBe(filename);
    expect(await readFile(await download.path(), "utf8")).toContain(contents);
  }
  await page.getByRole("button", { name: "I've saved it — close" }).click();
  await expect(page.getByText("synthetic-passphrase-success", { exact: true })).toHaveCount(0);
  await page.reload();
  await expect(page.getByText("synthetic-passphrase-success", { exact: true })).toHaveCount(0);
  expect(post.method()).toBe("POST");
  expect(post.headers()["x-pithead-control"]).toBe("1");
  expect(post.postData()).toBeNull();
});

test("creating phase blocks duplicate clicks and Escape", async ({ page, ui }) => {
  await page.clock.install();
  let posts = 0;
  let polls = 0;
  await page.route("**/api/control/backup", async (route) => {
    posts++;
    await route.fulfill({ status: 202, json: { id: "running" } });
  });
  await page.route("**/api/control/result?**", async (route) => {
    polls++;
    await route.fulfill(polls === 1 ? { status: 202 } : { json: applied("running") });
  });
  await mount(ui);

  const trigger = page.getByRole("button", { name: "Back up now" });
  await trigger.click();
  await page
    .getByRole("dialog", { name: "Create a backup" })
    .getByRole("button", { name: "Create backup" })
    .click();
  const creating = page.getByRole("dialog", { name: "Creating a backup…" });
  await expect(creating).toBeVisible();
  await expect(trigger).toBeDisabled();
  await page.keyboard.press("Escape");
  await expect(creating).toBeVisible();
  expect(posts).toBe(1);

  await page.clock.fastForward(2000);
  await expect.poll(() => polls).toBe(1);
  await page.clock.fastForward(2000);
  await expect(page.getByRole("heading", { name: "Backup created" })).toBeVisible();
  expect(posts).toBe(1);
});

test("a transient 502 during restart keeps polling to the backup result", async ({ page, ui }) => {
  await page.clock.install();
  let polls = 0;
  await page.route("**/api/control/backup", (route) =>
    route.fulfill({ status: 202, json: { id: "restart" } }),
  );
  await page.route("**/api/control/result?**", async (route) => {
    polls++;
    await route.fulfill(
      polls === 1 ? { status: 502, body: "upstream restarting" } : { json: applied("restart") },
    );
  });
  await mount(ui);

  await page.getByRole("button", { name: "Back up now" }).click();
  await page
    .getByRole("dialog", { name: "Create a backup" })
    .getByRole("button", { name: "Create backup" })
    .click();
  await page.clock.fastForward(2000);
  await expect.poll(() => polls).toBe(1);
  await page.clock.fastForward(2000);
  await expect(page.getByText("synthetic-passphrase-restart", { exact: true })).toBeVisible();
  expect(polls).toBe(2);
});

test("a failed backup shows the reason and can be retried", async ({ page, ui }) => {
  await page.clock.install();
  let posts = 0;
  await page.route("**/api/control/backup", async (route) => {
    posts++;
    await route.fulfill({ status: 202, json: { id: `attempt-${posts}` } });
  });
  await page.route("**/api/control/result?**", (route) => {
    const id = new URL(route.request().url()).searchParams.get("id");
    return route.fulfill({
      json:
        id === "attempt-1"
          ? { status: "failed", error: "backup archive could not be written" }
          : applied("attempt-2"),
    });
  });
  await mount(ui);

  const run = async () => {
    await page.getByRole("button", { name: "Back up now" }).click();
    await page
      .getByRole("dialog", { name: "Create a backup" })
      .getByRole("button", { name: "Create backup" })
      .click();
    await page.clock.fastForward(2000);
  };
  await run();
  await expect(page.getByText("backup archive could not be written")).toBeVisible();
  await page.getByRole("button", { name: "Close" }).click();
  await run();
  await expect(page.getByText("synthetic-passphrase-attempt-2", { exact: true })).toBeVisible();
  expect(posts).toBe(2);
});
