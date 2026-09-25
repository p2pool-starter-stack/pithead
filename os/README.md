# Appliance runtime units

The hand-written Quadlet unit set that ran the full stack under rootful Podman in
the #78 runtime spike (2026-07-24): seven `.container` units and two `.network` units,
brought up on a Debian 13 VM with both nodes remote. Preserved in `quadlet/` as the
reference output the phase-1 `pithead render-quadlet` renderer must reproduce.

Secrets, wallets, and the onion address are replaced with `rendered-*` /
`your_*_wallet_address` placeholders; everything else is exactly what ran, including
the fixes the spike forced (`TimeoutStartSec=infinity`, tmpfs `mode=` instead of
`uid=`/`gid=`). One value has moved since: the spike ran p2pool under a 1g cap, which
held only while hugepages carried its RandomX dataset. The cap is now 4g, so p2pool
survives a short pool as well (#2562).

These files are fixtures, not deployable configuration. They are consumed only as the
parity test's expected output (`tests/stack/run.sh`, `render_quadlet_units()` diffed
byte-for-byte against `quadlet/`, `quadlet/local/` and `quadlet/payout/`) — never
deployed directly; the appliance always renders its own units from `config.json`. The
translation rules the spike established, with evidence, live in
[`docs/dev/dual-distribution-plan.md`](../docs/dev/dual-distribution-plan.md)
(Runtime architecture) and on issue #78.
