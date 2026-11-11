#!/usr/bin/env bash
# Pure-file migration ownership and same-version fallback regressions.
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/tmp}}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:?}/migration-hold.XXXXXX")
trap 'rm -rf "$T"' EXIT
# shellcheck source=lib/pithead/15-os-update.sh
source "$ROOT/lib/pithead/15-os-update.sh"
# shellcheck source=os/overlay/pithead-boot
source "$ROOT/os/overlay/pithead-boot"
export PITHEAD_MIGRATION_MARKER_FILE="$T/.os-migration-pending" PITHEAD_CMDLINE="$T/cmdline" PITHEAD_VERSION=2.0.0
cd "$T"
cp "$ROOT/pithead" ./pithead
mkdir bin
printf '#!/bin/sh\nexit 0\n' >bin/sync
cat >bin/rauc <<'EOF'
#!/usr/bin/env bash
case "$*" in
'status --output-format=json') printf '%s\n' '{"slots":[{"rootfs.0":{"state":"booted","bootname":"A","boot_status":"good"}}]}' ;;
'status mark-bad other') printf '%s\n' "$*" >>rauc-calls ;;
*) exit 1 ;;
esac
EOF
chmod +x bin/sync bin/rauc
export PATH="$T/bin:$PATH"
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
printf 'quiet rauc.slot=B console=ttyS0\n' >cmdline
printf '2.0.0\n' >.os-migration-pending
claim_log=$(os_prepare_migration_hold) || fail 'candidate did not claim the legacy marker'
[ "$claim_log" = 'pithead-boot: migration marker claimed: 2.0.0|B' ] || fail 'the durable claim was not recorded'
[ "$(cat .os-migration-pending)" = '2.0.0|B' ] || fail 'marker has no slot owner'
os_migration_hold_active || fail 'doctor does not recognise the claimed hold'
claim_log=$(os_prepare_migration_hold) || fail 'same-slot reboot lost the hold'
[ "$claim_log" = 'pithead-boot: migration marker claimed: 2.0.0|B' ] || fail 'reboot did not record its owner'
printf 'quiet rauc.slot=A\n' >cmdline
if os_migration_hold_active; then fail 'same-version previous slot was held'; fi
# The previous release uses this exact version-only comparison; the qualified marker
# must also take its fallback path, even before that release learns about slot ownership.
[ "$(tr -d '[:space:]' <.os-migration-pending)" != "$PITHEAD_VERSION" ] || fail 'older boot treats fallback as a migration'
printf '2.0.0\n' >.os-data-floor
printf '1.20.0\n' >.os-data-floor.prev
restore_data_floor_after_fallback >/dev/null
[ "$(cat rauc-calls)" = "status mark-bad other" ] || fail 'fallback did not disarm the candidate'
[ "$(cat .os-data-floor)" = 1.20.0 ] || fail 'fallback did not restore the floor'
[ ! -e .os-migration-pending ] && [ ! -e .os-data-floor.prev ] || fail 'fallback markers survived'
if os_prepare_migration_hold; then fail 'absent marker held a normal boot'; fi
printf '2.0.0\n' >.os-migration-pending
printf 'quiet\n' >cmdline
rc=0
os_prepare_migration_hold || rc=$?
[ "$rc" = 2 ] || fail 'unreadable ownership permitted chain startup'
[ "$(cat .os-migration-pending)" = 2.0.0 ] || fail 'failed ownership changed the marker'
# Failure before publication retains the legacy marker and fails closed.
printf 'quiet rauc.slot=B\n' >cmdline
sync() { return 1; }
rc=0
os_prepare_migration_hold || rc=$?
[ "$rc" = 2 ] || fail 'failed durability check permitted startup'
[ "$(cat .os-migration-pending)" = 2.0.0 ] || fail 'failed publication truncated the marker'
unset -f sync
for corrupt in '' 'garbage' '2.0.0|C'; do
    printf '%s\n' "$corrupt" >.os-migration-pending
    rc=0
    os_prepare_migration_hold || rc=$?
    [ "$rc" = 2 ] || fail 'corrupt marker permitted chain startup'
done
printf 'quiet rauc.slot=B\n' >cmdline
printf '1.20.0\n' >.os-migration-pending
if os_prepare_migration_hold; then fail 'different-version marker held a normal boot'; fi
printf '1.20.0|B\n' >.os-migration-pending
rc=0
os_prepare_migration_hold || rc=$?
[ "$rc" = 2 ] || fail 'same-slot different-version marker permitted startup'
[ "$(cat .os-migration-pending)" = '1.20.0|B' ] || fail 'same-slot version mismatch changed protection'
# Establish ownership before any boot action that can fail and trigger fallback.
claim=$(awk '/^migration_fingerprint=\$\(bash -c/ {print NR}' "$ROOT/os/overlay/pithead-boot")
load=$(awk '/^\.\/pithead load-images/ {print NR}' "$ROOT/os/overlay/pithead-boot")
[ -n "$claim" ] && [ "$claim" -lt "$load" ] || fail 'ownership was deferred until after loading'
echo 'selftest-migration-hold: PASS'
