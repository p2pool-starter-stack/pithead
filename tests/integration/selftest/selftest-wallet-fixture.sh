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
python3 "$TEST_DIR/test-wallet-fixture-transport.py" || exit 1
python3 "$TEST_DIR/test-payout-docker-guard.py" || exit 1
python3 "$TEST_DIR/test-payout-pair-preparation.py" || exit 1
python3 "$TEST_DIR/test-payout-pair-model.py" || exit 1
python3 "$TEST_DIR/test-payout-pair-runtime.py" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CI_JOB_DIR="$WORK"
KEEP=0 BENCH_HOST=dummy-bench RESTORE_DIR=/dummy/baseline E2E_DIR=/dummy/branch
SSH_OPTS=() FAIL_SCAN=0 FAIL_ADDRESS=0 FAIL_IMPORT=0 FAIL_CLEANUP=0 FAIL_CATCHUP=0
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
on_bench() {
    echo catchup >>"$WORK/actions"
    [ "$FAIL_CATCHUP" = 0 ]
}
rx() { [ "$FAIL_SCAN" = 0 ]; }
api_state() { printf '{"earnings":{"confirmed":{"reachable":true,"address_match":%s}}}' "$([ "$FAIL_ADDRESS" = 0 ] && echo true || echo false)"; }
wait_for() {
    echo "$1/$2" >>"$WORK/waits"
    shift 3
    "$@"
}

echo "== wallet fixture: capture, import and readiness gates before cleanup =="
KEEP=1 wallet_fixture_capture >"$WORK/log"
assert_eq "keep mode does not capture a fixture" "$(cat "$WORK/log")" ""
wallet_fixture_capture >"$WORK/log"
assert_eq "capture durably arms the job before deployment" "$(cat "$WORK/wallet-fixture-restore.state")" ARMED
assert_contains "capture arms the binding runner protocol" "$(cat "$WORK/log")" " ✓ WALLET FIXTURE PRESERVATION ARMED"
wallet_fixture_restore >>"$WORK/log"
wallet_fixture_verify >>"$WORK/log"
assert_eq "successful gates durably verify the job" "$(cat "$WORK/wallet-fixture-restore.state")" VERIFIED
assert_eq "successful capture/import/gates removes the private archives" "$(cat "$WORK/actions")" $'catchup\ncapture\nrestore\ncleanup'
assert_eq "the original catch-up and dashboard waits are reused" "$(cat "$WORK/waits")" $'1200/15\n420/10'
assert_contains "proved restore emits the exact runner marker" "$(cat "$WORK/log")" " ✓ WALLET FIXTURE RESTORE VERIFIED"

echo "== wallet fixture: a bench-ci job directory (0775) still takes a private receipt =="
chmod 775 "$WORK"
rm -f "$WORK/wallet-fixture-restore.state"
wallet_fixture_receipt ARMED >"$WORK/log" 2>&1
assert_eq "a group-writable job directory still records the receipt" "$?" 0
assert_eq "the receipt is written" "$(cat "$WORK/wallet-fixture-restore.state")" ARMED
assert_eq "the job directory is no longer group or world writable" "$((8#$(stat -c %a "$WORK" 2>/dev/null || stat -f %Lp "$WORK") & 8#22))" 0
rm -f "$WORK/wallet-fixture-restore.state"

echo "== wallet fixture: a wallet still catching up after the backup is never captured =="
: >"$WORK/actions"
(FAIL_CATCHUP=1 wallet_fixture_capture) >"$WORK/log" 2>&1
assert_eq "an unfinished catch-up refuses the deployment" "$?" 1
assert_eq "an unfinished catch-up never snapshots the wallet" "$(cat "$WORK/actions")" catchup
assert_contains "an unfinished catch-up names its cause" "$(cat "$WORK/log")" "did not catch up after the safety backup"

echo "== wallet fixture: a failed gate refuses the restore and keeps the snapshot =="
: >"$WORK/actions"
wallet_fixture_receipt ARMED
RESTORE_PROOF_FAILED=0 WALLET_CACHE_IMPORTED=0 FAIL_IMPORT=1
wallet_fixture_restore >"$WORK/log" 2>&1
assert_eq "failed import refuses the restore" "$?" 1
assert_eq "failed import marks the baseline restore proof failed" "$RESTORE_PROOF_FAILED" 1
assert_eq "failed import durably records NOT_PROVEN" "$(cat "$WORK/wallet-fixture-restore.state")" NOT_PROVEN
assert_eq "failed import retains the private archives" "$(cat "$WORK/actions")" restore
FAIL_IMPORT=0 WALLET_CACHE_IMPORTED=1
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
    cleanup) assert_eq "cleanup failure exercises the cleanup path" "$(cat "$WORK/actions")" cleanup ;;
    esac
done

echo "== wallet fixture: an uncertain import blocks baseline wallet startup =="
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
