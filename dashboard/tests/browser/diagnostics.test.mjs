import { expect, test } from "./fixtures.mjs";

const mount = (ui) =>
  ui.mount(`
import { DiagnosticsPanel } from '/static/system/diagview.mjs';
render(html\`<\${DiagnosticsPanel} enabled=\${true} />\`, document.getElementById('fixture'));
`);

test("the read-only health check survives a transient restart and renders the report", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  let post;
  let polls = 0;
  await page.route("**/api/control/diag-doctor", async (route) => {
    post = route.request();
    await route.fulfill({ status: 202, json: { id: "doctor-1" } });
  });
  await page.route("**/api/control/result?**", async (route) => {
    polls++;
    await route.fulfill(
      polls === 1
        ? { status: 502, body: "restarting" }
        : {
            json: {
              status: "applied",
              doctor: {
                summary: { fail: 1, warn: 0, ok: 1 },
                checks: [
                  { status: "fail", message: "monerod is not answering — restart monerod." },
                  { status: "ok", message: "System clock is NTP-synchronized." },
                ],
              },
            },
          },
    );
  });
  await mount(ui);

  const run = page.getByRole("button", { name: "Run health check" });
  await run.click();
  await expect(run).toBeDisabled();
  await expect(page.getByText(/Waiting for the host/)).toBeVisible();
  await page.clock.fastForward(2000);
  await expect.poll(() => polls).toBe(1);
  await page.clock.fastForward(2000);
  await expect(page.getByText("1 failing, 0 warning, 1 ok")).toBeVisible();
  await expect(page.getByText("monerod is not answering — restart monerod.")).toBeVisible();

  expect(post.method()).toBe("POST");
  expect(post.headers()["x-pithead-control"]).toBe("1");
  expect(post.postDataJSON()).toEqual({});
  expect(polls).toBe(2);
});

test("a failed service-log read displays its reason and can be retried", async ({ page, ui }) => {
  await page.clock.install();
  const posts = [];
  await page.route("**/api/control/diag-logs", async (route) => {
    posts.push(route.request());
    await route.fulfill({ status: 202, json: { id: `tor-log-${posts.length}` } });
  });
  await page.route("**/api/control/result?**", (route) => {
    const id = new URL(route.request().url()).searchParams.get("id");
    return route.fulfill({
      json:
        id === "tor-log-1"
          ? { status: "rejected", error: "the requested service log is not available" }
          : { status: "applied", lines: "tor ready\ncircuit established" },
    });
  });
  await mount(ui);

  const tor = page.locator("section").filter({
    has: page.getByRole("heading", { name: "tor", exact: true }),
  });
  await tor.getByText("Recent log", { exact: true }).click();
  await tor.getByRole("button", { name: "Show recent log" }).click();
  await page.clock.fastForward(2000);
  await expect(tor.getByText("the requested service log is not available")).toBeVisible();
  await tor.getByRole("button", { name: "Refresh recent log" }).click();
  await page.clock.fastForward(2000);
  await expect(tor.locator("pre")).toContainText("tor ready\ncircuit established");

  expect(posts).toHaveLength(2);
  for (const request of posts) {
    expect(request.headers()["x-pithead-control"]).toBe("1");
    expect(request.postDataJSON()).toEqual({ container: "tor", lines: 200 });
  }
});

for (const theme of ["Light", "Dark"]) {
  test(`${theme} theme: the diagnostics controls render as bordered buttons with a focus ring`, async ({
    page,
    browserName,
    ui,
  }) => {
    const nextKey = browserName === "webkit" && process.platform === "darwin" ? "Alt+Tab" : "Tab";
    await mount(ui);
    await page.evaluate(
      (t) => document.documentElement.setAttribute("data-theme", t),
      theme.toLowerCase(),
    );
    await page.locator("summary", { hasText: "Recent log" }).first().click();
    await page.clock.install();
    await page.route("**/api/control/diag-logs", (route) =>
      route.fulfill({ status: 202, json: { id: "log-1" } }),
    );
    await page.route("**/api/control/result?**", (route) =>
      route.fulfill({ json: { status: "applied", lines: "tor ready" } }),
    );
    const run = page.getByRole("button", { name: "Run health check" });
    const show = page.getByRole("button", { name: "Show recent log" }).first();
    const refresh = page.getByRole("button", { name: "Refresh recent log" });
    const heading = page.getByRole("heading", { name: "Service diagnostics" });
    const section = page.locator("h3").first();
    const assertButton = async (control, start, tabs) => {
      await expect(control).toHaveCSS("border-top-width", "1px");
      await expect(control).toHaveCSS("border-top-style", "solid");
      await expect(control).toHaveCSS("border-top-left-radius", "6px");
      await start.click();
      for (let n = 0; n < tabs; n++) await page.keyboard.press(nextKey);
      await expect(control).toBeFocused();
      await expect(control).toHaveCSS("outline-style", "solid");
      await expect(control).toHaveCSS("outline-width", "2px");
    };
    await assertButton(run, heading, 1);
    await expect(run).toHaveClass(/active/);
    await assertButton(show, section, 2);
    await expect(show).not.toHaveClass(/active/);
    await show.click();
    await page.clock.fastForward(2000);
    await expect(refresh).toHaveCount(1);
    await assertButton(refresh, section, 2);
    await expect(refresh).not.toHaveClass(/active/);
    await page.evaluate(() => {
      for (const b of document.querySelectorAll("button")) b.disabled = true;
    });
    for (const control of [run, refresh]) {
      await expect(control).toHaveCSS("opacity", "0.5");
      await expect(control).toHaveCSS("cursor", "not-allowed");
    }
  });
}

test("toggle-group segments stay borderless", async ({ page, ui }) => {
  await ui.open();
  const segment = page.getByRole("group", { name: "Dashboard view" }).getByRole("button").first();
  await expect(segment).toHaveCSS("border-top-width", "0px");
});
