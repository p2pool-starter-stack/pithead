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
