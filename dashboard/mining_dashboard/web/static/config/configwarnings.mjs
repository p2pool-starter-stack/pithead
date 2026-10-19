// Inline warnings for the Configuration view's high-consequence fields, split out of
// configlogic.mjs (#2367). The form shows each before any preview round-trip; the host preview
// (lib/pithead/39*-describe-change*.sh) names the same cost again before the operator confirms.
// The pool text carries describe_change's P2POOL_FLAGS warning; the wallet texts its DEST messages.
export const FIELD_WARNINGS = {
  "p2pool.pool":
    "P2Pool sidechain changing — p2pool re-syncs the new sidechain and your PPLNS window resets (XvB shares reset too).",
  "p2pool.clearnet":
    "Tor is private by default but costs about 10% of P2Pool yield on mini. Clearnet exposes your home IP to P2Pool peers.",
  "xvb.tor":
    "Tor hides your home IP from the XvB donation pool. Turning it off connects directly and exposes your home IP to that pool.",
  "monero.wallet_address":
    "Monero payout address is changing — future mining rewards go to the new address.",
  "tari.wallet_address":
    "Tari payout address is changing — future merge-mining rewards go to the new address.",
  "dashboard.auth.password":
    "Dashboard login password changing — every other signed-in session is logged out, a mistyped password locks this session out too, and on the appliance it is also the console root login. Keep another way to reach this machine handy before you confirm.",
  "telegram.enabled":
    "Telegram bot — turning it off stops every Telegram alert, the wallet-change and clearnet-exposure tamper alarms included.",
  "telegram.bot_token":
    "Telegram bot token changing — a wrong token stops every Telegram alert, the tamper alarms included, and another bot's token sends them to that bot's owner.",
  "telegram.chat_id":
    "Telegram chat changing — a wrong id stops delivery or sends every alert, payout and wallet-change ones included, to another chat.",
  "healthchecks.ping_url":
    "Healthchecks ping URL changing — a wrong URL stops the pings or sends them to someone else's check, so an outage here goes unnoticed.",
  "telegram.events.wallet_changed":
    "Wallet-change alarm — turning it off means a payout-address change no longer alerts Telegram, so a wallet swap could go unnoticed.",
  "telegram.events.clearnet_exposed":
    "Clearnet-exposure alarm — turning it off means a node exposing this machine's IP over clearnet no longer alerts Telegram.",
  "dashboard.host":
    "Machine hostname changing — this is the approval-gated day-two rename: it reissues the local certificate and changes the appliance's mDNS identity. Rigs using the old name stop mining; use Set up again on each rig to point it at the new name.",
};
