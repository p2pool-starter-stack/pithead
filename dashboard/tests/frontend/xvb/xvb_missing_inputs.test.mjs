import assert from "node:assert/strict";
import test from "node:test";

import { XvbTierBlock } from "../../../mining_dashboard/web/static/xvb/xvbview.mjs";
import { render } from "../helpers/render.mjs";

const calc = {
  enabled: true,
  max_fraction: 0.85,
  estimates_available: false,
  estimates_stale: false,
  estimates_source: "none",
  note: "raffle status",
  tiers: [
    {
      name: "Vip (10.00 kH/s+)",
      threshold: 10000,
      expected_reward_year: null,
      realized_reward_year: null,
      assumed_reward_year_range: null,
      win_odds_day: null,
      players_avg: null,
    },
  ],
};

test("XvB calculator names every input missing from an unready fresh box (#1960)", () => {
  const waiting = render(XvbTierBlock, {
    calc,
    hr: 0,
    coeffDay: 0,
    energy: { xmr_price: 0, price_source: { feed: true } },
  });
  assert.match(waiting, /Hashrate Cost<\/h5><p[^>]*>needs hashrate/);
  assert.match(waiting, /Cost needs P2Pool network stats/);
  assert.match(waiting, /XvB says waiting for reward feed/);
  assert.match(waiting, /Fiat net unavailable: waiting for the price feed/);

  const tooSmall = render(XvbTierBlock, {
    calc,
    hr: 5000,
    coeffDay: 1e-7,
    energy: { xmr_price: 0, price_source: { feed: false } },
  });
  assert.match(tooSmall, /Hashrate Cost<\/h5><p[^>]*>below the lowest tier/);
  assert.match(tooSmall, /Net \(XvB says\)<\/h5><p[^>]*>insufficient hashrate/);
  assert.match(tooSmall, /set dashboard\.energy\.xmr_price or enable its price feed/);
});

test("a fresh reward feed can truthfully omit a custom tier (#1960)", () => {
  const customTier = render(XvbTierBlock, {
    calc: { ...calc, estimates_available: true },
    hr: 20000,
    coeffDay: 1e-7,
    energy: { xmr_price: 200, currency: "USD" },
  });
  assert.match(customTier, /XvB says no published reward for this tier/);
  assert.doesNotMatch(customTier, /waiting for reward feed/);
});
