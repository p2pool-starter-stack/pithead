# Appliance runtime units

The hand-written Quadlet unit set that ran the full stack under rootful Podman in
the #78 runtime spike (2026-07-24): seven `.container` units and two `.network` units,
brought up on a Debian 13 VM with both nodes remote. Preserved in `quadlet/` as the
reference output the phase-1 `pithead render-quadlet` renderer must reproduce.

Secrets, wallets, and the onion address are replaced with `rendered-*` /
`your_*_wallet_address` placeholders; everything else is exactly what ran, including
the fixes the spike forced (`TimeoutStartSec=infinity`, tmpfs `mode=` instead of
`uid=`/`gid=`). The p2pool cap changed from 1g to 4g so it survives a short hugepages
pool (#2562). The Tor unit now receives the selected P2Pool P2P port; the entrypoint
uses it for the onion target (#2936).

The xmrig-proxy unit uses the same degrading shell healthcheck as Compose: an absent or
nonexecutable script reports healthy; an executable probe keeps its own exit status.
`Notify=healthy` waits for that verdict with `TimeoutStartSec=infinity`.

These files are fixtures, not deployable configuration. The appliance always renders
its own units from `config.json`. `tests/stack/run.sh` compares each remote, local
and payout render byte-for-byte with its complete expected unit set and rejects
extra or missing units.

`quadlet/common/` stores byte-identical units once: six used by all three profiles,
plus the Monero node, Tari node, P2Pool and Tor units shared by local and payout.
Profile-specific units stay in `quadlet/` (remote), `quadlet/local/` and
`quadlet/payout/`, beside each profile's `fixture.env`. For each expected filename,
the parity test uses the profile-specific fixture when present, otherwise the
shared fixture. The explicit profile inventories keep remote renders free of local
node units and local renders free of payout wallet units; shared files do not
automatically enable units. The 17 stored units preserve all 33 original profile
outputs without regenerating expected bytes from the renderer. Changing expected
bytes still requires bench proof; deduplication does not replace that evidence.

Appliance boot remains Compose-managed through Podman. The KVM provision phase
renders a disposable native xmrig-proxy unit using the appliance proxy container's
immutable image ID, starts it without networking or published ports, checks healthy
notification and the real API probe, and verifies cleanup.

The translation rules the spike established, with evidence, live in
[`docs/dev/dual-distribution-plan.md`](../docs/dev/dual-distribution-plan.md)
(Runtime architecture) and on issue #78.
