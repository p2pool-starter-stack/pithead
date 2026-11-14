import { expect, test } from "./fixtures.mjs";

const DETAIL = {
  name: "rig1",
  found: true,
  editable: true,
  control_enabled: true,
  status: "mining",
  hashrate: "1.2 kH/s",
  rigforge: null,
  writable_keys: ["DONATION", "max_temp_c", "token"],
  rig_config: { DONATION: 5, max_temp_c: 70, token: { __secret__: true } },
  last_applied: {},
  history: [],
  hashrate_by_config: [],
  hashrate_history: { hashrate: [], markers: [] },
};

const mount = (ui) =>
  ui.mount(`
import { WorkerInspect } from '/static/workers/workerview.mjs';
render(html\`<\${WorkerInspect} name="rig1" onClose=\${() => {}} />\`, document.getElementById('fixture'));
`);

test("an unsaved worker edit survives Escape and applies only its writable diff", async ({
  page,
  ui,
}) => {
  const requests = [];
  await page.route("**/api/worker?**", (route) => route.fulfill({ json: DETAIL }));
  await page.route("**/api/control/worker-apply", async (route) => {
    requests.push(route.request());
    await route.fulfill({ json: { status: "applied", change_id: "worker-change-1" } });
  });
  await mount(ui);

  const dialog = page.getByRole("dialog", { name: "Worker rig1" });
  await expect(dialog).toBeVisible();
  await dialog.getByRole("spinbutton", { name: "DONATION" }).fill("7");
  await expect(dialog.getByText(/Unsaved — Apply before closing/)).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dialog).toBeVisible();
  expect(requests).toHaveLength(0);

  await dialog.getByRole("button", { name: "Apply to rig" }).click();
  await expect(dialog.getByRole("status")).toContainText("Applied");
  expect(requests).toHaveLength(1);
  expect(requests[0].headers()["x-pithead-control"]).toBe("1");
  expect(requests[0].postDataJSON()).toEqual({ worker: "rig1", changes: { DONATION: 7 } });
});

test("JSON mode refuses a key outside the rig's writable allowlist", async ({ page, ui }) => {
  let posts = 0;
  await page.route("**/api/worker?**", (route) => route.fulfill({ json: DETAIL }));
  await page.route("**/api/control/worker-apply", (route) => {
    posts++;
    return route.fulfill({ json: { status: "applied" } });
  });
  await mount(ui);

  const dialog = page.getByRole("dialog", { name: "Worker rig1" });
  await dialog.getByRole("button", { name: "JSON" }).click();
  await dialog.locator("textarea.worker-edit").fill('{"DONATION":7,"not_allowed":true}');
  await dialog.getByRole("button", { name: "Apply to rig" }).click();
  await expect(dialog.getByRole("status")).toContainText("Not writable: not_allowed");
  expect(posts).toBe(0);
});

test("a clean Worker Inspect dialog closes with Escape and reopens", async ({ page, ui }) => {
  let reads = 0;
  await page.route("**/api/worker?**", (route) => {
    reads++;
    return route.fulfill({ json: DETAIL });
  });
  await ui.mount(`
import { Component } from '/static/app/preact.mjs';
import { WorkerInspect } from '/static/workers/workerview.mjs';
class Harness extends Component {
  constructor() { super(); this.state = { open: false }; }
  render() {
    return html\`<button onClick=\${() => this.setState({ open: true })}>Open worker</button>
      \${this.state.open ? html\`<\${WorkerInspect} name="rig1" onClose=\${() => this.setState({ open: false })} />\` : null}\`;
  }
}
render(html\`<\${Harness} />\`, document.getElementById('fixture'));
`);

  const open = page.getByRole("button", { name: "Open worker" });
  await open.click();
  const dialog = page.getByRole("dialog", { name: "Worker rig1" });
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
  await open.click();
  await expect(dialog).toBeVisible();
  expect(reads).toBe(2);
});

test("the Workers table labels each mining verdict and lists an unnamed proxy client", async ({
  page,
  ui,
}) => {
  const base = ui.state.workers[0];
  const row = (name, ip, extra) => ({ ...base, name, ip, ...extra });
  ui.state.workers = [
    row("rig-here", "10.0.0.1", {
      status: "online",
      mining: { state: "mining_here", pool: "h:3333" },
    }),
    row("rig-away", "10.0.0.2", {
      status: "online",
      mining: { state: "on_backup", pool: "backup.example:3333" },
      telemetry_h60: 31000,
      telemetry_str: "31.00 kH/s",
    }),
    row("rig-dark", "10.0.0.3", {
      status: "offline",
      mining: { state: "not_connected", pool: null },
    }),
    row("rig-unk", "10.0.0.4", { status: "online", mining: { state: "unknown", pool: null } }),
    row("rig-tele", "10.0.0.5", {
      status: "offline",
      mining: { state: "mining_here", pool: null },
      telemetry_h60: 3100,
      telemetry_str: "3.10 kH/s",
    }),
    row("unnamed proxy worker (10.0.0.9)", "10.0.0.9", {
      status: "online",
      unnamed: true,
      mining: { state: "unknown", pool: null },
    }),
  ];
  await ui.open();
  await page
    .getByRole("group", { name: "Dashboard view" })
    .getByRole("button", { name: "Advanced", exact: true })
    .click();

  const table = page.locator("#workers-table");
  const rowOf = (text) => table.locator("tbody tr", { hasText: text });
  await expect(rowOf("rig-away")).toContainText("on backup pool: backup.example:3333");
  await expect(rowOf("rig-away")).toContainText("DOWN");
  await expect(rowOf("rig-away")).toContainText("31.00 kH/s");
  await expect(rowOf("rig-dark")).toContainText("not connected to this Pithead");
  await expect(rowOf("rig-unk")).toContainText("mining location unknown");
  await expect(rowOf("rig-tele")).toContainText("telemetry only — not this Pithead");
  await expect(rowOf("rig-here")).not.toContainText("on backup pool");
  const unnamed = rowOf("unnamed proxy worker (10.0.0.9)");
  await expect(unnamed).toContainText("10.0.0.9");
  await expect(unnamed.locator(".worker-name-link")).toHaveCount(0);
});
