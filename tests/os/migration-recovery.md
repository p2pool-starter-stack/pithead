# Persisted release migration proof

The provision phase requires a runner-owned RC2 baseline at
`f5a5ad096c7a5345609a2eed4f600fd750a425ab`, with matching immutable service images.
The hand-off supplies `PITHEAD_OLD_IMAGE`, `PITHEAD_OLD_IMAGE_COMMIT` and
`PITHEAD_OLD_DASHBOARD_IMAGE` (a digest-qualified reference). The runner verifies
source, image checksum, service pins and signing trust, and reserves the image
and shared nodes for the run. `old_image=true` alone and mutable version tags do
not establish RC2. The exact selector is tracked in bench-ci#1629.

After the earlier provision legs, the battery provisions a disposable RC2 guest.
It verifies the guest source and dashboard image identity and retains local
Monero/Tari configuration. It enables the guest miner, waits for an existing
snapshot, stops the old dashboard and seeds its release through that inspected
image's `StateManager.save_snapshot`. The writer runs as UID:GID 1000:1000 against
its existing database mount, without network access. An independent SQLite
connection must confirm persistence; the database's owner, mode and inode must
stay unchanged. The old dashboard stays stopped until upgrade.

The candidate's migration boot must record its durable marker claim with the
booted A/B slot, P2Pool and proxy stopped at the ordinary health gate, an
unattended bootloader commit, and local-chain startup after commit. Missing
hold or commit evidence prevents remote recovery configuration. The existing
reserved `PITHEAD_OS_MONERO_*` and `PITHEAD_OS_TARI_*` inputs are then applied
through the authenticated configuration flow. A fresh persisted release,
direct synchronized RPC, healthy mining services and an increasing hash counter
establish recovery. The original local configuration is restored before the
same-version and floor-fallback legs.

This seeded regression proves the migration coordination path and mining
recovery through reserved nodes. The owner's RC3 upgrade on an appliance with
real synced chains provides separate real-chain acceptance; it does not gate
this PR. The withdrawn disposable-snapshot fixture is not required.
