#!/usr/bin/env bash
# Prepared cache must return before startup; its original readiness gates must pass before cleanup.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/wallet-fixture.sh
source "$HERE/lib/wallet-fixture.sh"
python3 "$TEST_DIR/test-wallet-fixture.py" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CI_JOB_DIR="$WORK"
KEEP=0 BENCH_HOST=dummy-bench RESTORE_DIR=/dummy/baseline E2E_DIR=/dummy/branch
SSH_OPTS=() FAIL_SCAN=0 FAIL_ADDRESS=0 FAIL_IMPORT=0 FAIL_CLEANUP=0
ok() { printf ' ✓ %s\n' "$*"; }
warn() { printf ' ! %s\n' "$*"; }
die() {
    echo "$*" >&2
    exit 1
}
wallet_fixture_command() {
    echo "$1" >>"$WORK/actions"
    case "$1" in
    capture) echo /private/dummy-fixture ;;
    restore) [ "$FAIL_IMPORT" = 0 ] ;;
    cleanup) [ "$FAIL_CLEANUP" = 0 ] ;;
    esac
}
wallet_scan_sample() { :; }
rx() { [ "$FAIL_SCAN" = 0 ]; }
api_state() { printf '{"earnings":{"confirmed":{"reachable":true,"address_match":%s}}}' "$([ "$FAIL_ADDRESS" = 0 ] && echo true || echo false)"; }
wait_for() {
    echo "$1/$2" >>"$WORK/waits"
    shift 3
    "$@"
}

KEEP=1 wallet_fixture_capture >"$WORK/log"
assert_eq "keep mode does not capture a fixture" "$(cat "$WORK/log")" ""
wallet_fixture_capture >"$WORK/log"
assert_eq "capture durably arms the job before deployment" "$(cat "$WORK/wallet-fixture-restore.state")" ARMED
assert_contains "capture arms the binding runner protocol" "$(cat "$WORK/log")" " ✓ WALLET FIXTURE PRESERVATION ARMED"
wallet_fixture_restore >>"$WORK/log"
wallet_fixture_verify >>"$WORK/log"
assert_eq "successful gates durably verify the job" "$(cat "$WORK/wallet-fixture-restore.state")" VERIFIED
assert_eq "successful capture/import/gates removes the private snapshot" "$(cat "$WORK/actions")" $'capture\nrestore\ncleanup'
assert_eq "the original catch-up and dashboard waits are reused" "$(cat "$WORK/waits")" $'1200/15\n420/10'
assert_contains "proved restore emits the exact runner marker" "$(cat "$WORK/log")" " ✓ WALLET FIXTURE RESTORE VERIFIED"

for failure in scan address cleanup; do
    : >"$WORK/actions"
    FAIL_SCAN=0 FAIL_ADDRESS=0 FAIL_CLEANUP=0
    rm -f "$WORK/wallet-fixture-restore.state"
    wallet_fixture_receipt ARMED
    case "$failure" in scan) FAIL_SCAN=1 ;; address) FAIL_ADDRESS=1 ;; cleanup) FAIL_CLEANUP=1 ;; esac
    wallet_fixture_verify >"$WORK/log" 2>&1
    assert_eq "$failure failure refuses a successful restore" "$?" 1
    assert_contains "$failure failure emits the binding failure marker" "$(cat "$WORK/log")" " ! WALLET FIXTURE RESTORE NOT PROVEN"
    case "$failure" in
    scan | address) assert_eq "readiness failure retains snapshot" "$(cat "$WORK/actions")" "" ;;
    esac
done

# Exercise the shipped EXIT restore, not a duplicate ordering implementation.
RESTORE_SRC="$(sed -n '/^restore_all() {$/,/^}$/p' "$HERE/e2e.sh")"
(
    # shellcheck disable=SC2034,SC2329 # variables/functions consumed by eval of the shipped restore.
    MODE=targeted RESTORED=0 MINER_CFG_BACKUP="" RESTORE_PROOF_FAILED=0
    # shellcheck disable=SC2034
    CONTROL_PROOF_FAILED=0 CONTROL_VERDICT_BEFORE="" SAFETY_ARCHIVE=""
    # shellcheck disable=SC2329
    parent_lock_checkpoint() { :; }
    # shellcheck disable=SC2329
    parent_lock_miner_restore() { :; }
    # shellcheck disable=SC2329
    drain_harness_or_refuse() { :; }
    # shellcheck disable=SC2329
    chain_restore_prepare() { :; }
    # shellcheck disable=SC2329
    step() { :; }
    # shellcheck disable=SC2329
    log() { :; }
    # shellcheck disable=SC2329
    control_units_verdict() { echo on-target; }
    # shellcheck disable=SC2329
    on_bench() {
        case "$1" in
        *dashboard/Dockerfile*) return 0 ;;
        *"{ ./pithead upgrade; }"*) echo baseline-start >>"$WORK/ordering" ;;
        esac
    }
    # shellcheck disable=SC2329
    wallet_fixture_restore() {
        echo cache-import >>"$WORK/ordering"
        return 1
    }
    eval "$RESTORE_SRC"
    restore_all
) >"$WORK/log" 2>&1
assert_eq "uncertain import fails the outer restore" "$?" 1
assert_eq "uncertain import prevents baseline wallet startup" "$(cat "$WORK/ordering")" cache-import

# shellcheck disable=SC2031 # child restore counters deliberately isolated; parent assertions count the result.
echo "wallet fixture shell: $IT_PASS passed, $IT_FAIL failed"
# shellcheck disable=SC2031
[ "$IT_FAIL" -eq 0 ]
