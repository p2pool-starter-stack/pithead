#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?set TMPDIR or RUNNER_TEMP}}"
HERE=$(cd "$(dirname "$0")" && pwd)
python3 "$HERE/selftest-migration-recovery.py"
# shellcheck source=tests/os/migration-recovery.sh
source "$HERE/migration-recovery.sh"
SCRIPT_DIR=$HERE
T=$(mktemp -d "${TMPDIR:?}/migration-recovery.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
# Use actual Git ancestry, including a side branch and the candidate's own commits.
(
    mkdir "$T/repo"
    cd "$T/repo"
    git init -q --initial-branch=develop
    git config user.name fixture
    git config user.email fixture@example.invalid
    echo old >file
    git add file
    git commit -qm old
    old=$(git rev-parse HEAD)
    echo develop >file
    git commit -qam develop
    base=$(git rev-parse HEAD)
    git update-ref refs/remotes/origin/develop "$base"
    git checkout -qb candidate
    echo candidate >file
    git commit -qam candidate
    candidate=$(git rev-parse HEAD)
    git checkout -qb side "$old"
    echo side >file
    git commit -qam side
    side=$(git rev-parse HEAD)
    git checkout -q candidate
    migration_old_commit_valid "$old" && migration_old_commit_valid "$base" || fail 'merged old source rejected'
    for invalid in "$candidate" "$side" "${old:0:12}" "$(printf '%040d' 1)"; do
        if migration_old_commit_valid "$invalid" 2>/dev/null; then fail 'unmerged, PR or malformed source accepted'; fi
    done
    [ "$MIGRATION_BASE_REF" = origin/develop ] && [ "$MIGRATION_BASE_COMMIT" = "$base" ] || fail 'remote base identity not retained'
    git update-ref refs/remotes/origin/develop "$old"
    if migration_old_commit_valid "$base" 2>/dev/null; then fail 'local base overrode valid remote base'; fi
    git update-ref -d refs/remotes/origin/develop
    migration_old_commit_valid "$base" || fail 'mirror local base rejected'
    [ "$MIGRATION_BASE_REF" = refs/heads/develop ] && [ "$MIGRATION_BASE_COMMIT" = "$base" ] || fail 'mirror base identity not retained'
    for invalid in "$candidate" "$side"; do
        if migration_old_commit_valid "$invalid" 2>/dev/null; then fail 'mirror accepted PR or unmerged source'; fi
    done
    git update-ref refs/remotes/origin/develop "$(git hash-object -w file)"
    migration_old_commit_valid "$old" || fail 'non-commit remote ref prevented mirror fallback'
    git update-ref -d refs/remotes/origin/develop
    git update-ref -d refs/heads/develop
    if migration_old_commit_valid "$old" 2>/dev/null; then fail 'missing develop reference accepted'; fi
)
# Refuse an invalid selected source before the old guest's provisioning or seed.
(
    bad() { :; }
    unset PITHEAD_OLD_IMAGE
    _vm_boot_disk() { fail 'missing image reached guest destruction'; }
    if migration_prepare_old; then fail 'missing cached baseline accepted'; fi
    PITHEAD_OLD_IMAGE="$T/image"
    : >"$PITHEAD_OLD_IMAGE"
    _vm_boot_disk() { :; }
    _wait_ssh() { :; }
    _ssh() { git rev-parse HEAD; }
    _wizard_provision_capture() { fail 'PR source reached provisioning'; }
    if migration_prepare_old; then fail 'candidate branch baseline accepted'; fi
)
# Missing recovery input must refuse before configuration capture or mutation.
(
    unset PITHEAD_OS_TARI_GRPC_PORT
    PITHEAD_OS_MONERO_NODE_HOST=monero.example PITHEAD_OS_TARI_NODE_HOST=tari.example
    PITHEAD_OS_MONERO_RPC_PORT=18081 PITHEAD_OS_MONERO_ZMQ_PORT=18083
    approval_capture_restore_snapshot() { fail 'missing node input reached capture'; }
    if migration_remote_recovery; then fail 'missing reserved node input accepted'; fi
)
# A healthy positive carried counter is insufficient; it must advance in fresh samples.
for mode in advancing stalled malformed unhealthy; do
    printf '0\n' >"$T/time"
    printf '10\n' >"$T/hashes"
    date() {
        local n
        n=$(cat "$T/time")
        echo "$n"
        echo "$((n + 600))" >"$T/time"
    }
    sleep() { :; }
    _ssh() {
        local h
        h=$(cat "$T/hashes")
        if [ "$mode" = advancing ]; then echo "$((h + 1))" >"$T/hashes"; fi
        if [ "$mode" = malformed ]; then echo 'ready 2 garbage'; else echo "ready 2 $h"; fi
    }
    migration_services_healthy() { [ "$mode" != unhealthy ]; }
    result=fail
    if migration_wait_for_mining 0; then result=pass; fi
    if [ "$mode" = advancing ]; then expected=pass; else expected=fail; fi
    [ "$result" = "$expected" ] || fail "mining poll $mode"
done
unset -f date sleep _ssh
# The real phase must not substitute remote readiness for any held-boot evidence.
# shellcheck disable=SC2034 # sourced helpers read runner globals.
OS_RUN_SUITE=1
# shellcheck source=tests/os/phases/provision-migration.sh
source "$HERE/phases/provision-migration.sh"
for missing in none candidate commit hold claim stopped startup marker; do
    (
        pv_user=user pv_pass=pass marker=""
        calls="$T/calls"
        : >"$calls"
        ok() { :; }
        bad() { :; }
        info() { :; }
        sleep() { :; }
        migration_prepare_old() { :; }
        migration_seed_old() { echo seed >>"$calls"; }
        _build_bundle() {
            : >"$T/good"
            echo "$T/good"
        }
        preserve_migration_bundle() { echo "$1"; }
        _stage_bundle() { :; }
        _phase_provision_migration_space_refusal() { :; }
        _reboot_wait() { echo boot >>"$calls"; }
        _marker() { echo vmig; }
        assert_appliance_hostname_identity() { :; }
        _ssh() {
            case "$1" in
            'cat /opt/pithead/BUILD_COMMIT')
                if [ "$missing" = candidate ]; then printf '%040d\n' 1; else git rev-parse HEAD; fi
                ;;
            *'./pithead os-update'*) grep -qx seed "$calls" || fail 'upgrade before seed' ;;
            *'cat /data/pithead/.os-migration-pending'*) echo 2.0.0 ;;
            *'grub-editenv'*) [ "$missing" != commit ] ;;
            *'holding chain services'*) [ "$missing" != hold ] ;;
            *'migration marker claimed'*) [ "$missing" != claim ] ;;
            *'pithead-boot-status.log'*) [ "$missing" != stopped ] ;;
            *'podman inspect monerod minotari_node'*) [ "$missing" != startup ] ;;
            *'test -f /data/pithead/.os-migration-pending'*) [ "$missing" = marker ] ;;
            'date +%s') echo 100 ;;
            *'chain services released'*) return 0 ;;
            *) fail "unexpected guest query: $1" ;;
            esac
        }
        migration_remote_recovery() {
            grep -qx boot "$calls" || fail 'remote before boot'
            echo remote >>"$calls"
        }
        migration_wait_for_mining() { grep -qx remote "$calls" || fail 'recovery without configuration'; }
        approval_restore_pending() { echo restore >>"$calls"; }
        phase_provision_chain_fault_after_release() { grep -qx restore "$calls" || fail 'fault before restore'; }
        phase_provision_same_version_fallback() { echo same-version >>"$calls"; }
        phase_provision_floor_fallback_leg() { echo floor >>"$calls"; }
        _phase_provision_migration
        if [ "$missing" = none ]; then
            grep -qx remote "$calls" || fail 'complete commit proof did not recover'
        elif grep -qx remote "$calls"; then
            fail "$missing proof was replaced by remote readiness"
        fi
        grep -qx same-version "$calls" && grep -qx floor "$calls" || fail 'fallback coverage lost'
    )
done
echo 'selftest-migration-recovery: PASS'
