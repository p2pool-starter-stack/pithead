# Optional project donation

The project donation sends an opt-in time slice of your hashrate to a stratum endpoint run for Pithead.

## XMRig developer donation

XMRig, the miner your rigs run, donates a share of its time to the XMRig developers. Each
rig has its own level. The proxy has none: `proxy.donate_level` stays 0 and is not shown in
the dashboard. A rig that mines through Pithead's proxy sends its donation through that proxy,
so the level adds no direct internet connection from the rig.

- **Set it per rig.** Machines › rig › Advanced › Support the XMRig developers offers Off, 1 %,
  2 % and 5 % (XMRig donates whole percents only). Review shows the share, the time (for 1 %:
  1 minute in every 100 minutes, roughly 15 minutes a day) and the estimated cost at the rig's
  current hashrate. Typing `APPLY` writes the rig's `DONATION` through the control path.
- **Default is Off** for rigs RigForge builds (rigforge#603). Pithead never changes a rig's level except by that explicit action;
  adopting a rig shows its current level.
- **The shown level is the miner's own report** (`donate_level` in its summary), not only the
  configured one. When they differ the panel says so. A running level above the configured one
  needs a RigForge update to lower; a lower one applies after the miner restarts.
- **Unmanaged rigs** (no control path) and stock XMRig rigs show the level read-only, or
  "Own donation: unknown". Stock XMRig donates at least 1 %. They have no control.
- **Fleet view.** Earnings shows the hashrate-weighted share and how many rigs donate. It
  reports "unavailable" when any hashing rig does not report a level, never 0 %. The expected
  earnings figures (still unavailable on that page) are to subtract this share; the Overview
  strip reads the same `xmrig_donation` figure.
- **To stop**, set the rig to Off and wait for the miner to report 0 %.

The same figure is published as `/api/state.xmrig_donation`:
`{"available", "percent", "rigs", "donating", "unknown"}`; `percent` is present only when
`available` is true.

## Availability and destination

The feature ships off by default, with empty destination constants. The setting appears only
in releases that publish a project endpoint. An empty destination means no project donation
route, setting, chart band or egress row appears. This page describes the supported behavior
when a destination is published; it is not an announcement that the endpoint is live.

| Destination field | Shipped value |
|---|---|
| Recipient | Pending publication |
| Project address | Pending publication |
| Endpoint | Pending publication |
| Endpoint kind | Pending publication (`onion` or `clearnet`) |

The recipient, project address and endpoint are shipped constants, not editable settings.
The project endpoint mines to the project address. Your own P2Pool instance still pays your
wallet; it does not split a payout or transfer coins out of your wallet. The cost is the
P2Pool earnings you give up while that hashrate mines for the project.

This is separate from XMRig's built-in 1 % developer fee, xmrig-proxy's
[`proxy.donate_level`](configuration.md#configuration-reference), and the
[XvB donation](privacy.md#xvb-donation-mining-166---tor-by-default) used to hold a raffle tier.
None of those pays Pithead.

## Cost

`donation.percent` selects an integer percentage from 1 to 10. The nominal time per day is
`1,440 × percentage / 100` minutes:

| Percentage | Minutes per day |
|---|---|
| 1 % | 14.4 |
| 2 % | 28.8 |
| 5 % | 72 |
| 10 % | 144 |

These are daily equivalents, not a promise of a slice every cycle. Small allocations can
accumulate across cycles. XvB tier holding and the P2Pool reserve take priority: when there
is not enough time left, the project slice is reduced first and the dashboard reports the
reduction. The actual donated time can therefore be lower than the configured percentage.

For a model estimate, expected XMR over 30 days is
`(percentage / 100) × H × 86,400 × 30 × R / D`, where `H` is the P2Pool hashrate average in
hashes per second, `R` is the Monero block reward in XMR and `D` is the Monero network
difficulty. This is the existing P2Pool earnings model, excluding XvB rewards. For example,
using illustrative inputs of `H = 10,000`, `R = 0.6` and `D = 660,000,000,000`, a 1 % slice
is about `0.00024 XMR` per 30 days. These are example inputs, not current network figures
or a measured payout. The amount is small; mining variance, rejected shares and changes in
difficulty or reward make actual earnings differ. A fiat estimate additionally needs an
XMR price and its observation time; no current price is assumed here.

The settings cost estimate is shown before enabling. It identifies its basis: recorded
payouts when enough tracking history exists, otherwise the network model, or unavailable
when inputs are missing or stale. A recorded-payout basis needs at least 30 days of tracking
and an adjustment for hashrate already donated. The model formula above is an estimate,
not a guaranteed reduction in your next payout.

## Route and privacy

The supported endpoint kinds are onion and clearnet. The proposed project deployment is
onion-only; supporting a clearnet kind does not mean the project has deployed one.

- **Onion:** the connection stays inside Tor and uses no exit relay. An onion destination
  requires Tor; setting `donation.tor` to `false` cannot make it directly reachable.
- **Clearnet, Tor enabled (default):** the connection uses Tor and the endpoint sees a Tor
  exit address.
- **Clearnet, direct routing chosen:** `donation.tor` set to `false` exposes your public IP
  to the endpoint operator. This is an explicit privacy choice.

The project connection sends no donor payout address, worker names or per-donor label.
The endpoint can observe connection timing, submitted shares and the hashrate those shares
imply. Tor does not hide that activity from the recipient. See the
[privacy disclosure](privacy.md#project-donation-mining) and the
[FAQ](faq.md#is-the-project-donation-mandatory).

## Verify receipts

Once a destination is published, compare the recipient and project address shown in the
release with the shipped destination. Do not substitute the manual-transfer address in
the [README](../README.md#-donate) for an unpublished hashpower destination.

Use a [Monero view-only wallet](https://www.getmonero.org/resources/user-guides/view_only.html)
with the project's public address and a published private view key,
if the project publishes one, to scan the chain for incoming receipts. A public address
alone does not reveal incoming amounts on Monero's blockchain. No project view key is
published by this page, so it does not claim public receipt auditing is available.
A project wallet receipt shows aggregate mining income, not which donor supplied a hash;
there is no per-donor label to match to a payout. Dashboard slice records show routing
activity, not proof that a particular share became a confirmed on-chain payout.

## Stop donating and endpoint outages

Set `donation.enabled` to `false` and apply the change. Project slices stop within one
10-minute cycle. Disabling the project donation does not disable the separate XvB or
miner developer-fee mechanisms.

If the project endpoint is down or stops accepting work, the project slice ends and the
rigs return to P2Pool. Endpoint failure does not justify keeping rigs on a dead route.
See [configuration](configuration.md#configuration-reference) for the config editor and
[privacy](privacy.md#project-donation-mining) for the egress disclosure.
