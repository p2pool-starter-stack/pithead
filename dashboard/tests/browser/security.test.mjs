import { expect, test } from "./fixtures.mjs";

const access = (entries) => ({
  available: true,
  failures_24h: 1,
  last_failure_ts: 1_760_000_000,
  rotate_hint: false,
  entries,
});
const entry = (i, uri = `/request/${i}`) => ({
  ts: 1_760_000_000 + i,
  status: i === 0 ? 401 : 200,
  method: "GET",
  uri,
  user: `operator-${i}`,
});
const mount = (ui) =>
  ui.mount(`
import { SecurityPanel } from '/static/system/securityview.mjs';
render(html\`<\${SecurityPanel} />\`, document.getElementById('fixture'));
`);

test("the real Configuration view shows access and audit data with hostile text inert", async ({
  page,
  ui,
}) => {
  ui.state.control_enabled = true;
  const hostilePath = '<img src="x" onerror="window.securityPwned=1">';
  const hostileActor = "<script>window.securityPwned=2</script>";
  const mutations = [];
  page.on("request", (request) => {
    if (request.method() !== "GET") mutations.push(request.url());
  });
  await page.route("**/api/config", (route) =>
    route.fulfill({ json: { p2pool: { pool: "mini" }, _editable_keys: [] } }),
  );
  await page.route("**/api/access", (route) =>
    route.fulfill({ json: access([entry(0, hostilePath), entry(1)]) }),
  );
  await page.route("**/api/audit", (route) =>
    route.fulfill({
      json: {
        entries: [
          {
            ts: "2026-10-09T12:00:00Z",
            actor: hostileActor,
            action: "commit-approved",
            status: "applied",
            keys: "dashboard.energy.xmr_price",
          },
        ],
      },
    }),
  );

  await ui.open();
  await page
    .getByRole("group", { name: "Dashboard view" })
    .getByRole("button", { name: "Configuration", exact: true })
    .click();
  await expect(page.getByRole("heading", { name: "Access log" })).toBeVisible();
  await expect(page.getByText(hostilePath, { exact: true })).toBeVisible();
  await expect(page.getByText(hostileActor, { exact: true })).toBeVisible();
  await expect(page.getByText("Approved configuration change")).toBeVisible();
  await expect(page.getByText("dashboard.energy.xmr_price", { exact: true })).toBeVisible();
  expect(await page.evaluate(() => window.securityPwned)).toBeUndefined();
  await expect(page.locator('img[src="x"]')).toHaveCount(0);
  await expect(page.locator("script").filter({ hasText: "window.securityPwned" })).toHaveCount(0);
  expect(mutations).toEqual([]);
});

test("access filters map to requests and reset pagination to the first result page", async ({
  page,
  ui,
}) => {
  await page.clock.install({ time: new Date("2026-10-09T12:00:00Z") });
  const urls = [];
  await page.route("**/api/access**", (route) => {
    const url = new URL(route.request().url());
    urls.push(url);
    const rows =
      url.searchParams.get("q") === "needle"
        ? Array.from({ length: 6 }, (_, i) => entry(i, `/needle/${i}`))
        : Array.from({ length: 12 }, (_, i) => entry(i));
    return route.fulfill({ json: access(rows) });
  });
  await page.route("**/api/audit", (route) => route.fulfill({ json: { entries: [] } }));
  await mount(ui);

  await page.getByRole("combobox", { name: "Access log: rows per page" }).selectOption("5");
  await page.getByRole("button", { name: "Access log: next page" }).click();
  await expect(page.getByText("12 entries · page 2 of 3")).toBeVisible();
  await expect(page.getByText("/request/5", { exact: true })).toBeVisible();

  await page.getByRole("searchbox", { name: "Access log filter: search" }).fill("needle");
  await page.clock.fastForward(300);
  await expect(page.getByText("6 entries · page 1 of 2")).toBeVisible();
  await expect(page.getByText("/needle/0", { exact: true })).toBeVisible();
  expect(urls.at(-1).searchParams.get("q")).toBe("needle");

  await page.getByLabel("Access log filter: from date").fill("2026-10-01");
  await page.getByLabel("Access log filter: to date").fill("2026-10-02");
  await expect.poll(() => urls.length).toBeGreaterThanOrEqual(4);
  const dated = urls.at(-1).searchParams;
  expect(dated.get("from")).toBe(String(Date.parse("2026-10-01") / 1000));
  expect(dated.get("to")).toBe(String(Date.parse("2026-10-03") / 1000));
  expect(dated.get("q")).toBe("needle");
});

test("a failed filter request keeps visible data and the next filter retries", async ({
  page,
  ui,
}) => {
  let filtered = 0;
  await page.route("**/api/access**", (route) => {
    const url = new URL(route.request().url());
    if (!url.search) return route.fulfill({ json: access([entry(0, "/still-visible")]) });
    filtered++;
    return filtered === 1
      ? route.fulfill({ status: 503, body: "temporarily unavailable" })
      : route.fulfill({ json: access([entry(1, "/recovered")]) });
  });
  await page.route("**/api/audit", (route) => route.fulfill({ json: { entries: [] } }));
  await mount(ui);

  await expect(page.getByText("/still-visible", { exact: true })).toBeVisible();
  const filters = page.getByRole("group", { name: "Access log filter" });
  await filters.getByRole("button", { name: "24 Hr" }).click();
  await expect.poll(() => filtered).toBe(1);
  await expect(page.getByText("/still-visible", { exact: true })).toBeVisible();
  await filters.getByRole("button", { name: "1 Wk" }).click();
  await expect(page.getByText("/recovered", { exact: true })).toBeVisible();
  await expect(page.getByText("/still-visible", { exact: true })).toHaveCount(0);
});

test("a slow stale filter response cannot overwrite the newest access results", async ({
  page,
  ui,
}) => {
  let staleRoute;
  let filtered = 0;
  await page.route("**/api/access**", async (route) => {
    const url = new URL(route.request().url());
    if (!url.search) return route.fulfill({ json: access([entry(0, "/initial")]) });
    filtered++;
    if (filtered === 1) {
      staleRoute = route;
      return;
    }
    await route.fulfill({ json: access([entry(1, "/newest-7d")]) });
  });
  await page.route("**/api/audit**", (route) => {
    const queried = new URL(route.request().url()).search.length > 0;
    return route.fulfill({
      json: {
        entries: queried
          ? [
              {
                ts: "2026-10-09T12:00:00Z",
                actor: "race-sentinel",
                action: "commit",
                status: "applied",
                keys: "dashboard.auth.username",
              },
            ]
          : [],
      },
    });
  });
  await mount(ui);

  const filters = page.getByRole("group", { name: "Access log filter" });
  await filters.getByRole("button", { name: "24 Hr" }).click();
  await expect.poll(() => !!staleRoute).toBe(true);
  await filters.getByRole("button", { name: "1 Wk" }).click();
  await expect(page.getByText("/newest-7d", { exact: true })).toBeVisible();
  const staleResponse = page.waitForResponse(staleRoute.request().url());
  await staleRoute.fulfill({ json: access([entry(2, "/stale-24h")]) });
  await (await staleResponse).finished();
  await page
    .getByRole("group", { name: "Config-change filter" })
    .getByRole("button", { name: "24 Hr" })
    .click();
  await expect(page.getByText("race-sentinel", { exact: true })).toBeVisible();
  await expect(page.getByText("/newest-7d", { exact: true })).toBeVisible();
  await expect(page.getByText("/stale-24h", { exact: true })).toHaveCount(0);
});
