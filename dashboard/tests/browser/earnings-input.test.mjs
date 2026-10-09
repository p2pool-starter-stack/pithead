import { expect, test } from "./fixtures.mjs";

test("earnings calculator converts grouped thousands and rejects malformed hashrate", async ({
  page,
  ui,
}) => {
  await ui.mount(`
// Match the production Advanced view so its card is visible under the real stylesheet.
document.body.classList.add('mode-advanced');
import { EarningsCard } from '/static/app/earnings.mjs';
render(html\`<\${EarningsCard} earnings=\${{
  available: true, p2pool_hr: 1000, p2pool_hr_str: '1000 H/s',
  coeff_day: 0.001, pool_difficulty: 1000,
}} />\`, document.getElementById('fixture'));
`);
  const input = page.getByRole("textbox", { name: "Your P2Pool Hashrate" });
  await expect(input).toBeVisible();
  const coins = page.locator("#epanel-monero .est-table tbody td.c-accent");
  const expected = ["1.0000 XMR", "30.0000 XMR", "365.0000 XMR"];
  async function expectCoins(values) {
    await expect(coins).toHaveText(values);
  }
  await expectCoins(expected);
  await input.fill("10");
  await expectCoins(["0.010000 XMR", "0.300000 XMR", "3.650000 XMR"]);
  for (const [value, values] of [
    ["1,000", expected],
    ["10garbage", ["—", "—", "—"]],
    ["1 kH/s", expected],
    ["1e3", ["—", "—", "—"]],
  ]) {
    await test.step(value, async () => {
      await input.fill(value);
      await expectCoins(values);
    });
  }
});
