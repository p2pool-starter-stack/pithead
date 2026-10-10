import { expect, test } from "./fixtures.mjs";

const archive = {
  name: "synthetic-backup.tar.gz.enc",
  mimeType: "application/octet-stream",
  buffer: Buffer.from("synthetic encrypted bytes\u0000\u00ff"),
};

test.beforeEach(async ({ page }) => {
  await page.route("**/api/wizard-state", (route) =>
    route.fulfill({
      json: {
        stage: "setup",
        config: { monero: { mode: "local" } },
        reference: {},
        disks: [],
        restore_enabled: true,
      },
    }),
  );
});

test("restore requires an archive and masks the passphrase again after leaving the form", async ({
  page,
  ui,
}) => {
  const submissions = [];
  await page.route("**/submit-restore", (route) => {
    submissions.push(route.request().postData());
    return route.fulfill({ status: 400 });
  });
  await ui.openWizard();
  const restore = page.getByRole("button", {
    name: "Restoring an existing Pithead? Upload its backup instead.",
  });
  await restore.click();
  await page.getByRole("button", { name: "Restore and provision", exact: true }).click();
  await expect(page.getByText("Choose a backup archive to upload.", { exact: true })).toBeVisible();
  expect(submissions).toEqual([]);
  const passphrase = page.getByLabel("Passphrase", { exact: true });
  await passphrase.fill("synthetic-recovery-passphrase");
  await expect(passphrase).toHaveAttribute("type", "password");
  await page.getByRole("checkbox", { name: "Show passphrase" }).check();
  await expect(passphrase).toHaveAttribute("type", "text");
  await page.getByRole("button", { name: /Back to/ }).click();
  await restore.click();
  await expect(passphrase).toHaveAttribute("type", "password");
  await expect(page.getByRole("checkbox", { name: "Show passphrase" })).not.toBeChecked();
  await page.reload();
  await restore.click();
  await expect(passphrase).toHaveValue("");
});

test("a refused restore preserves the upload for a corrected passphrase and sends exact multipart bytes", async ({
  page,
  ui,
}) => {
  const uploads = [];
  // WebKit's intercepted request omits file bytes; inspect the actual HTTP upload instead.
  ui.responses.set("/submit-restore", async (request) => {
    expect(request.method).toBe("POST");
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const form = await new Response(Buffer.concat(chunks), {
      headers: { "content-type": request.headers["content-type"] },
    }).formData();
    uploads.push({
      keys: [...form.keys()],
      passphrase: form.get("passphrase"),
      filename: form.get("archive").name,
      bytes: Buffer.from(await form.get("archive").arrayBuffer()),
    });
    if (uploads.length === 1)
      return {
        status: 400,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ error: "Wrong archive passphrase." }),
      };
    await page.route("**/api/wizard-state", (stateRoute) =>
      stateRoute.fulfill({
        json: { stage: "installing", config: {}, reference: {}, disks: [], restore_enabled: true },
      }),
    );
    return { status: 202, headers: { "Content-Type": "application/json" }, body: "{}" };
  });
  await page.route("**/status", (route) => route.fulfill({ body: "Validating restored settings" }));
  await ui.openWizard();
  await page.getByRole("button", { name: /Restoring an existing Pithead/ }).click();
  await page.getByLabel("Backup archive", { exact: true }).setInputFiles(archive);
  await page.getByLabel("Passphrase", { exact: true }).fill("wrong");
  await page.getByRole("button", { name: "Restore and provision", exact: true }).click();
  await expect(page.getByText("Wrong archive passphrase.", { exact: true })).toBeVisible();
  await expect(page.getByText(`${archive.name} (0 KB)`, { exact: true })).toBeVisible();
  await page.getByLabel("Passphrase", { exact: true }).fill("corrected synthetic passphrase");
  await page.getByRole("button", { name: "Restore and provision", exact: true }).click();
  await expect(page.getByText("Installing.", { exact: true })).toBeVisible();
  expect(uploads).toEqual(
    ["wrong", "corrected synthetic passphrase"].map((passphrase) => ({
      keys: ["archive", "passphrase"],
      passphrase,
      filename: archive.name,
      bytes: archive.buffer,
    })),
  );
  await expect(page.getByLabel("Passphrase", { exact: true })).toHaveCount(0);
});

test("setup does not offer restore when the server reports HTTPS restore unavailable", async ({
  page,
  ui,
}) => {
  await page.route("**/api/wizard-state", (route) =>
    route.fulfill({
      json: {
        stage: "setup",
        config: { monero: { mode: "local" } },
        reference: {},
        disks: [],
        restore_enabled: false,
      },
    }),
  );
  await ui.openWizard();
  await expect(
    page.getByText("Restore from a backup requires HTTPS. Reboot after setup TLS is available.", {
      exact: true,
    }),
  ).toBeVisible();
  await expect(page.getByRole("button", { name: /Restoring an existing Pithead/ })).toHaveCount(0);
  await expect(page.getByLabel("Backup archive", { exact: true })).toHaveCount(0);
});

test("installer restore requires a target and its exact erase confirmation", async ({
  page,
  ui,
}) => {
  await page.route("**/api/wizard-state", (route) =>
    route.fulfill({
      json: {
        stage: "installer",
        config: { monero: { mode: "local" } },
        reference: {},
        restore_enabled: true,
        disks: [
          { name: "vda", model: "Synthetic test disk", size: "100 GB", state: "pithead-with-data" },
        ],
      },
    }),
  );
  let submitted;
  await page.route("**/submit-restore", async (route) => {
    const req = route.request();
    const form = await new Response(req.postDataBuffer(), {
      headers: { "content-type": req.headers()["content-type"] },
    }).formData();
    submitted = { disk: form.get("disk"), confirm: form.get("confirm"), wipe: form.get("wipe") };
    return route.fulfill({
      status: 400,
      json: { error: "Synthetic host refusal: no disk was modified." },
    });
  });
  await ui.openWizard();
  await page.getByRole("button", { name: /Restoring an existing Pithead/ }).click();
  await expect(page.getByLabel("Backup archive", { exact: true })).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Restore and provision", exact: true }),
  ).toHaveCount(0);
  await page.getByRole("combobox", { name: "Target disk", exact: true }).selectOption("vda");
  await page.getByLabel("Backup archive", { exact: true }).setInputFiles(archive);
  const confirm = page.getByLabel("Type the disk name to confirm", { exact: true });
  await confirm.fill("VDA");
  await page.getByRole("button", { name: "Restore and provision", exact: true }).click();
  await expect(
    page.getByText("Type vda exactly to confirm the erase.", { exact: true }),
  ).toBeVisible();
  expect(submitted).toBeUndefined();
  await confirm.fill("vda");
  await page.getByRole("button", { name: "Restore and provision", exact: true }).click();
  await expect(
    page.getByText("Synthetic host refusal: no disk was modified.", { exact: true }),
  ).toBeVisible();
  expect(submitted).toEqual({ disk: "vda", confirm: "vda", wipe: "keep" });
});

test("a dropped restore connection keeps the archive and permits a deliberate retry", async ({
  page,
  ui,
}) => {
  let attempts = 0;
  await page.route("**/submit-restore", (route) => {
    attempts++;
    return attempts === 1
      ? route.abort()
      : route.fulfill({ status: 400, json: { error: "Archive validation failed." } });
  });
  await ui.openWizard();
  await page.getByRole("button", { name: /Restoring an existing Pithead/ }).click();
  await page.getByLabel("Backup archive", { exact: true }).setInputFiles(archive);
  await page.getByLabel("Passphrase", { exact: true }).fill("synthetic passphrase");
  const submit = page.getByRole("button", { name: "Restore and provision", exact: true });
  await submit.click();
  await expect(
    page.getByText("Could not reach this machine. Retry when it is available.", { exact: true }),
  ).toBeVisible();
  await expect(page.getByLabel("Passphrase", { exact: true })).toHaveValue("synthetic passphrase");
  await submit.click();
  await expect(page.getByText("Archive validation failed.", { exact: true })).toBeVisible();
  expect(attempts).toBe(2);
});

test("restore refuses an oversized archive before uploading any bytes", async ({
  page,
  ui,
}, testInfo) => {
  // A sparse file exercises the real file chooser without retaining a 64 MiB JS buffer per browser.
  const { open } = await import("node:fs/promises");
  const path = testInfo.outputPath("oversized.enc");
  const file = await open(path, "w");
  await file.truncate(64 * 1024 * 1024 + 1);
  await file.close();
  const submissions = [];
  await page.route("**/submit-restore", (route) => {
    submissions.push(route.request().url());
    return route.fulfill({ status: 400 });
  });
  await ui.openWizard();
  await page.getByRole("button", { name: /Restoring an existing Pithead/ }).click();
  await page.getByLabel("Backup archive", { exact: true }).setInputFiles(path);
  await page.getByRole("button", { name: "Restore and provision", exact: true }).click();
  await expect(page.getByText(/Archive is too large \(max 64 MB\)/)).toBeVisible();
  expect(submissions).toEqual([]);
});
