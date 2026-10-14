import { expect, test } from "./fixtures.mjs";

test("network details expand, internal mesh persists, and refreshed posture replaces the old summary", async ({
  page,
  ui,
}) => {
  await page.clock.install();
  await page.route("**/api/miner-connection", (route) =>
    route.fulfill({ json: { url: "stratum+tcp://example.invalid:3333", password_set: false } }),
  );
  await ui.open();
  await page
    .getByRole("group", { name: "Dashboard view" })
    .getByRole("button", { name: "Advanced", exact: true })
    .click();
  const card = page.locator("#card-egress");
  const svg = card.getByRole("img", { name: /^Stack network topology/ });
  await expect(svg).toBeVisible();
  await expect(svg.getByText("docker-proxy", { exact: true })).toHaveCount(0);
  await card.getByRole("button", { name: "Show internal mesh", exact: true }).click();
  await expect(svg.getByText("docker-proxy", { exact: true })).toBeVisible();
  await expect(
    card.getByRole("button", { name: "Hide internal mesh", exact: true }),
  ).toHaveAttribute("aria-pressed", "true");
  await page.reload();
  await expect(svg.getByText("docker-proxy", { exact: true })).toBeVisible();
  await card.getByText("All connections (per component)", { exact: true }).click();
  await expect(card.getByText("remote Tari node (sync gRPC)", { exact: true })).toBeVisible();
  await expect(card.locator(".egress-summary")).toContainText("All egress via Tor");
  Object.assign(ui.state.topology.summary, {
    level: "warn",
    leaks: 1,
    label: "Synthetic route warning",
  });
  await page.clock.fastForward(30000);
  await expect(card.locator(".egress-summary")).toContainText("Synthetic route warning");
  await expect(card.locator(".egress-summary")).toHaveClass(/c-bad/);
  await expect(svg.getByText("docker-proxy", { exact: true })).toBeVisible();
  await card.getByRole("button", { name: "Hide internal mesh", exact: true }).click();
  await expect(svg.getByText("docker-proxy", { exact: true })).toHaveCount(0);
});
