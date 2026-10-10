import { expect, test } from "./fixtures.mjs";

const CONFIG = {
  p2pool: { pool: "mini" },
  monero: { mode: "local", wallet_address: "4Addr", view_key: { __secret__: true } },
  _core_keys: ["p2pool.pool"],
  _editable_keys: ["p2pool.pool", "monero.mode", "monero.wallet_address", "monero.view_key"],
};

test("the Expected vs Actual view-key hint opens Configuration on the Payouts section (#3359)", async ({
  page,
  ui,
}) => {
  ui.state.earnings_summary.xmr = {
    available: true,
    expected_30d: 0.0123,
    includes_xvb: false,
    enabled: false,
    actual_30d: null,
    partial: false,
    pct: null,
    xvb_realization_pct: null,
    xvb_wins_measured: null,
  };
  await page.addInitScript(() => localStorage.setItem("dashboardView", "advanced"));
  await page.route("**/api/config", (route) => route.fulfill({ json: CONFIG }));
  await ui.open();
  const hint = page.locator(".eva-hint").filter({ hasText: "Not tracked" });
  await expect(hint).toContainText("Configuration → Payouts.");
  await hint.getByRole("button", { name: "Configuration", exact: true }).click();

  const payouts = page.locator("details.config-section[data-section=\"Payouts\"]");
  await expect(payouts).toHaveAttribute("open", "");
  await expect(payouts.locator("summary")).toBeFocused();
  await expect(payouts.locator(".config-field-name", { hasText: /^view_key$/ })).toBeVisible();
  // The node section the old text named stays collapsed: the hint no longer sends anyone there.
  await expect(page.locator("details.config-section[data-section=\"Monero node\"]")).not.toHaveAttribute(
    "open",
    "",
  );
});
