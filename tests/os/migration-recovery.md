# Persisted release migration proof

Submit the provision phase with `old_image=true`. The runner supplies its
verified cached image as `PITHEAD_OLD_IMAGE`, keeping its normal checksum,
registry, signing-trust and reservation checks. The battery records the selected
guest's full BUILD_COMMIT and requires it to be an ancestor of the verified
develop commit and outside the PR commits. It resolves `origin/develop` first,
then `refs/heads/develop` for the runner's full mirror checkout, and records
the selected ref and full SHA. Neither resolving to a commit is an explicit
failure, as is missing, malformed or unmerged baseline source. The baseline and candidate share VERSION but are identified by
BUILD_COMMIT. An exact RC2 selector is not required; bench-ci#1629 is not a
prerequisite. The owner's appliance provides the exact RC2-to-RC3 acceptance.

After the earlier provision legs, the battery provisions that disposable old
guest with explicit local Monero/Tari wizard answers, including the reserved
Tari wallet. This avoids an old wizard capacity default of Tari off omitting
the wallet before the later full-config preview. Ordinary capture callers keep
the wizard's defaults. It enables the guest miner, waits
for an existing snapshot, stops the old dashboard and seeds its release through
that inspected image's `StateManager.save_snapshot`. It records the dashboard
image ID. The writer runs as UID:GID 1000:1000 against its existing database
mount, without network access. An independent SQLite connection must confirm
persistence; the database's owner, mode and inode must stay unchanged. The old
dashboard stays stopped until upgrade.

The candidate's migration boot must record its BUILD_COMMIT, durable marker
claim with the booted A/B slot, P2Pool and proxy stopped at the ordinary health
gate, an unattended bootloader commit, and local-chain startup after commit.
Missing hold or commit evidence prevents remote recovery configuration. The
existing reserved `PITHEAD_OS_MONERO_*` and `PITHEAD_OS_TARI_*` inputs are then
applied through the authenticated configuration flow. A fresh persisted release,
direct synchronized RPC, healthy mining services and an increasing hash counter
establish recovery. The original local configuration is restored before the
same-version and floor-fallback legs.

This seeded regression proves migration coordination and mining recovery through
reserved nodes. The owner's RC3 upgrade with real synced chains provides separate
real-chain acceptance; it does not gate this PR. The withdrawn disposable
snapshot fixture and exact-baseline selector are not required.
