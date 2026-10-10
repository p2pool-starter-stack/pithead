import { expect, test } from "./fixtures.mjs";

const TOKEN = "0123456789abcdef0123456789abcdef";
const UPDATE = {
  available: true,
  latest: "v1.11.2",
  url: "https://example.test/v1.11.2",
};
const PREVIEW = {
  id: "adopt-1",
  status: "previewed",
  destructive: true,
  changes: [
    {
      flag: "CONFIRM",
      key: "workers.list",
      msg: "Adopting rig1 at 10.0.0.9 sends its control token to that address.",
    },
  ],
};

const mountAdopt = (ui) =>
  ui.mount(`
import { AdoptRigForm } from '/static/workers/workeradopt.mjs';
render(html\`<\${AdoptRigForm} name="rig1" ip="10.0.0.9" />\`, document.getElementById('fixture'));
`);

const mountUpgrade = (ui) =>
  ui.mount(`
import { RigUpgrade } from '/static/workers/workerupgrade.mjs';
const update = ${JSON.stringify(UPDATE)};
render(html\`<\${RigUpgrade} name="rig1" update=\${update} canEdit=\${true} busy=\${false}
  onDone=\${() => document.body.dataset.done = String(Number(document.body.dataset.done || 0) + 1)} />\`,
  document.getElementById('fixture'));
`);

test("adoption previews the exact config and commits only after typed APPLY", async ({
  page,
  ui,
}) => {
  const live = {
    network: { subnet: "172.28.0.0/24" },
    workers: {
      enabled: true,
      list: [{ name: "rig0", host: "10.0.0.8", port: 8081 }],
    },
  };
  const writes = [];
  await page.route("**/api/config", (route) => route.fulfill({ json: live }));
  await page.route("**/api/control/preview", async (route) => {
    writes.push(route.request());
    await route.fulfill({ json: PREVIEW });
  });
  await page.route("**/api/control/commit", async (route) => {
    writes.push(route.request());
    await route.fulfill({ json: { id: "adopt-1", status: "applied" } });
  });
  await mountAdopt(ui);

  await page.getByLabel("token").fill(TOKEN);
  await page.getByRole("button", { name: "Adopt this rig" }).click();
  await expect(page.getByText(PREVIEW.changes[0].msg)).toBeVisible();
  const confirm = page.getByRole("button", { name: "Confirm" });
  await expect(confirm).toBeDisabled();
  expect(writes).toHaveLength(1);
  expect(writes[0].headers()["x-pithead-control"]).toBe("1");
  expect(writes[0].postDataJSON()).toEqual({
    config: {
      network: { subnet: "172.28.0.0/24" },
      workers: {
        enabled: true,
        list: [
          { name: "rig0", host: "10.0.0.8", port: 8081 },
          {
            name: "rig1",
            host: "10.0.0.9",
            port: 8081,
            control_port: 8082,
            token: TOKEN,
          },
        ],
      },
    },
  });

  await page.getByLabel(/Type APPLY/).fill("APPLY");
  await confirm.click();
  await expect(page.getByText(/Saved to config\.json/)).toBeVisible();
  expect(writes).toHaveLength(2);
  expect(writes[1].headers()["x-pithead-control"]).toBe("1");
  expect(writes[1].postDataJSON()).toEqual({ id: "adopt-1", confirm: "APPLY" });
});

test("adoption refuses malformed and internal hosts before preview", async ({ page, ui }) => {
  let configReads = 0;
  let previews = 0;
  await page.route("**/api/config", async (route) => {
    configReads++;
    await route.fulfill({ json: { network: { subnet: "172.28.0.0/24" } } });
  });
  await page.route("**/api/control/preview", async (route) => {
    previews++;
    await route.fulfill({ json: PREVIEW });
  });
  await mountAdopt(ui);
  await page.getByLabel("token").fill(TOKEN);

  await page.getByLabel("host").fill("10.0.0.9:9999");
  await page.getByRole("button", { name: "Adopt this rig" }).click();
  await expect(page.getByText(/no port or path/)).toBeVisible();
  expect(configReads).toBe(0);

  await page.getByLabel("host").fill("127.0.0.1");
  await page.getByRole("button", { name: "Adopt this rig" }).click();
  await expect(page.getByText(/inside this stack's own network/)).toBeVisible();
  expect(configReads).toBe(1);
  expect(previews).toBe(0);
});

test("adoption refuses an unexpected disruptive preview without offering commit", async ({
  page,
  ui,
}) => {
  let commits = 0;
  await page.route("**/api/config", (route) => route.fulfill({ json: {} }));
  await page.route("**/api/control/preview", (route) =>
    route.fulfill({
      json: {
        ...PREVIEW,
        changes: [
          ...PREVIEW.changes,
          {
            flag: "CONFIRM",
            key: "MONERO_PRUNE",
            msg: "Also disables pruning",
          },
        ],
      },
    }),
  );
  await page.route("**/api/control/commit", async (route) => {
    commits++;
    await route.fulfill({ json: { status: "applied" } });
  });
  await mountAdopt(ui);

  await page.getByLabel("token").fill(TOKEN);
  await page.getByRole("button", { name: "Adopt this rig" }).click();
  await expect(page.getByText("Unexpected change — nothing was applied.")).toBeVisible();
  await expect(page.getByLabel(/Type APPLY/)).toHaveCount(0);
  expect(commits).toBe(0);
});

test("upgrade arms, cancels, and sends the confirmed version with the control header", async ({
  page,
  ui,
}) => {
  const requests = [];
  await page.route("**/api/control/worker-upgrade", async (route) => {
    requests.push(route.request());
    await route.fulfill({ json: { status: "noop", note: "already current" } });
  });
  await mountUpgrade(ui);

  const arm = page.getByRole("button", { name: "Upgrade rig…" });
  await arm.click();
  await expect(page.getByRole("button", { name: "Confirm upgrade" })).toBeVisible();
  expect(requests).toHaveLength(0);
  await page.getByRole("button", { name: "Cancel" }).click();
  await expect(arm).toBeVisible();
  expect(requests).toHaveLength(0);

  await arm.click();
  await page.getByRole("button", { name: "Confirm upgrade" }).click();
  await expect(page.getByRole("status")).toContainText("Already up to date");
  expect(requests).toHaveLength(1);
  expect(requests[0].headers()["x-pithead-control"]).toBe("1");
  expect(requests[0].postDataJSON()).toEqual({
    worker: "rig1",
    version: "v1.11.2",
  });
});

test("an accepted upgrade polls through running to success", async ({ page, ui }) => {
  await page.clock.install();
  let polls = 0;
  await page.route("**/api/control/worker-upgrade", (route) =>
    route.fulfill({
      status: 202,
      json: { id: "upgrade-1", status: "pending" },
    }),
  );
  await page.route("**/api/control/result?**", async (route) => {
    polls++;
    if (polls === 1) return route.fulfill({ status: 202, json: { status: "running" } });
    await route.fulfill({
      json: { status: "applied", change_id: "rig-upgrade-1" },
    });
  });
  await mountUpgrade(ui);

  await page.getByRole("button", { name: "Upgrade rig…" }).click();
  await page.getByRole("button", { name: "Confirm upgrade" }).click();
  await expect(page.getByText(/upgrading — a rebuild can take minutes/)).toBeVisible();
  await page.clock.fastForward(2000);
  await expect.poll(() => polls).toBe(1);
  await page.clock.fastForward(2000);
  await expect(page.getByRole("status")).toContainText("Applied · rig-upgrade-1");
  expect(polls).toBe(2);
  await expect(page.locator("body")).toHaveAttribute("data-done", "1");
});

test("a failed upgrade exposes its reason and can be retried", async ({ page, ui }) => {
  let attempts = 0;
  await page.route("**/api/control/worker-upgrade", async (route) => {
    attempts++;
    await route.fulfill({
      json:
        attempts === 1
          ? { status: "failed", reason: "rig did not return live" }
          : { status: "applied", change_id: "retry-1" },
    });
  });
  await mountUpgrade(ui);

  for (const expected of ["Failed — rig did not return live", "Applied · retry-1"]) {
    await page.getByRole("button", { name: "Upgrade rig…" }).click();
    await page.getByRole("button", { name: "Confirm upgrade" }).click();
    await expect(page.getByRole("status")).toContainText(expected);
  }
  expect(attempts).toBe(2);
  await expect(page.locator("body")).toHaveAttribute("data-done", "2");
});

test("the dashboard worker row opens Inspect and reaches its upgrade action", async ({
  page,
  ui,
}) => {
  ui.state.control_enabled = true;
  ui.state.workers[0].rigforge_update = UPDATE;
  const detail = {
    name: "rig-alpha",
    found: true,
    editable: true,
    control_enabled: true,
    status: "mining",
    hashrate: "5.1 kH/s",
    rigforge: { version: "v1.11.1", stats: [] },
    rigforge_update: UPDATE,
    writable_keys: ["DONATION"],
    rig_config: { DONATION: 5 },
    last_applied: {},
    history: [],
    hashrate_by_config: [],
    hashrate_history: { hashrate: [], markers: [] },
  };
  let workerReads = 0;
  let posted;
  await page.route("**/api/worker?**", (route) => {
    workerReads++;
    return route.fulfill({ json: detail });
  });
  await page.route("**/api/control/worker-upgrade", async (route) => {
    posted = route.request();
    await route.fulfill({ json: { status: "applied", change_id: "from-inspect" } });
  });
  await ui.open();

  await page.getByRole("button", { name: "rig-alpha", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Worker rig-alpha" });
  await expect(dialog.getByText(/New RigForge release v1\.11\.2/)).toBeVisible();
  await dialog.getByRole("button", { name: "Upgrade rig…" }).click();
  await dialog.getByRole("button", { name: "Confirm upgrade" }).click();
  await expect.poll(() => workerReads).toBe(2);
  expect(posted.headers()["x-pithead-control"]).toBe("1");
  expect(posted.postDataJSON()).toEqual({ worker: "rig-alpha", version: "v1.11.2" });
});

test("upgrade controls obey edit, update, and parent-busy gates", async ({ page, ui }) => {
  await ui.mount(`
import { RigUpgrade } from '/static/workers/workerupgrade.mjs';
const update = ${JSON.stringify(UPDATE)};
render(html\`<section aria-label="uneditable"><\${RigUpgrade} name="rig1" update=\${update} canEdit=\${false} /></section>
  <section aria-label="busy"><\${RigUpgrade} name="rig1" update=\${update} canEdit=\${true} busy=\${true} /></section>
  <section aria-label="current"><\${RigUpgrade} name="rig1" update=\${null} canEdit=\${true} /></section>\`,
  document.getElementById('fixture'));
`);

  const uneditable = page.getByRole("region", { name: "uneditable" });
  await expect(uneditable.getByText(/New RigForge release/)).toBeVisible();
  await expect(uneditable.getByRole("button")).toHaveCount(0);
  await expect(page.getByRole("region", { name: "busy" }).getByRole("button")).toBeDisabled();
  await expect(
    page.getByRole("region", { name: "current" }).getByText(/New RigForge release/),
  ).toHaveCount(0);
});
