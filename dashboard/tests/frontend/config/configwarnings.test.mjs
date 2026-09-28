// The Configuration view's inline warnings (configwarnings.mjs, #2367): each high-consequence
// field names its cost in the form before any preview round-trip.
import assert from "node:assert/strict";
import { test } from "node:test";

import { buildSections } from "../../../mining_dashboard/web/static/config/configlogic.mjs";

test("buildSections: high-consequence fields carry their inline warning", () => {
  const tg = { bot_token: { __secret__: true }, chat_id: "1111" };
  tg.events = { wallet_changed: true, clearnet_exposed: true };
  const cfg = {
    p2pool: { pool: "mini" },
    monero: { wallet_address: "4AAAA", prune: true },
    dashboard: { auth: { password: { __secret__: true } }, host: "box.lan" },
    telegram: { ...tg, enabled: true },
    healthchecks: { ping_url: { __secret__: true } },
  };
  const fields = Object.fromEntries(
    buildSections(cfg)
      .flatMap((s) => s.fields)
      .map((f) => [f.key, f]),
  );
  assert.match(fields["p2pool.pool"].warning, /PPLNS window resets/);
  assert.match(fields["monero.wallet_address"].warning, /payout address/);
  assert.equal(fields["monero.prune"].warning, undefined);
  // #2367: the password and hostname name their consequence before the operator confirms.
  assert.match(fields["dashboard.auth.password"].warning, /logged out|locks this session/);
  assert.match(fields["dashboard.host"].warning, /approval-gated day-two rename/);
  assert.match(fields["telegram.events.wallet_changed"].warning, /wallet swap could go unnoticed/);
  assert.match(fields["telegram.events.clearnet_exposed"].warning, /exposing this machine's IP/);
  assert.match(fields["telegram.enabled"].warning, /stops every Telegram alert.*tamper alarms/);
  assert.match(fields["telegram.bot_token"].warning, /stops every Telegram alert.*another bot/);
  assert.match(fields["telegram.chat_id"].warning, /stops delivery.*another chat/);
  assert.match(fields["healthchecks.ping_url"].warning, /someone else's check.*goes unnoticed/);
});
