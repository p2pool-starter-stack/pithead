#!/usr/bin/env bash
# Operator recovery of a retained wallet fixture: the Python contract, then the shell-only steps
# (start the baseline, run the readiness gate, verify the runner's lock) against stubs. No bench.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$(cd "$TEST_DIR/.." && pwd)"
python3 "$TEST_DIR/test-wallet-recovery.py" || exit 1
python3 "$TEST_DIR/test-wallet-recovery-interface.py" || exit 1
python3 "$TEST_DIR/test-wallet-recovery-live.py" || exit 1

# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/wallet-fixture-recovery.sh
source "$HERE/lib/wallet-fixture-recovery.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/log"
mkdir -p "$WORK/source/dashboard" "$WORK/bundle"
: >"$WORK/source/dashboard/Dockerfile"

# shellcheck disable=SC2329 # stubs for the collaborators the sourced steps call
stub_start_collaborators() {
    chain_restore_prepare() { echo prepare >>"$LOG"; }
    on_bench() { echo "run: $1" >>"$LOG"; }
    recovery_wait_synced() { echo "synced $1" >>"$LOG"; }
    recovery_wait_healthy() { echo "healthy $1" >>"$LOG"; }
    wait_restore_mining_ready() { echo "mining $1" >>"$LOG"; }
}

echo "== the baseline starts through the command the e2e restore uses, then waits =="
stub_start_collaborators
: >"$LOG"
recovery_start "$WORK/source"
assert_rc "a source checkout starts" "$?" 0
assert_eq "it converges the stack, upgrades with its own images, then waits for sync, health and mining" \
    "$(cat "$LOG")" "$(printf 'prepare\nrun: cd '"'%s'"' && { ./pithead upgrade; }\nsynced 1500\nhealthy 300\nmining 1500' "$WORK/source")"
: >"$LOG"
recovery_start "$WORK/bundle"
assert_contains "a release bundle applies and ups instead" "$(cat "$LOG")" "{ ./pithead apply -y && ./pithead up; }"
assert_eq "an upgrade is never run against a bundle" "$(grep -c 'pithead upgrade' "$LOG")" "0"
on_bench() {
    echo "run: $1" >>"$LOG"
    return 1
}
: >"$LOG"
recovery_start "$WORK/source" 2>/dev/null
assert_rc "a failed start command fails the step" "$?" 1
assert_eq "and nothing waits on a stack that did not start" "$(grep -cE '^(synced|healthy|mining)' "$LOG")" "0"
stub_start_collaborators

echo "== the readiness gate is the e2e restore's own and every failure is binding =="
FAIL_SCAN=0 FAIL_ADDRESS=0 # recovery_ready resets IT_FAIL, so every call below runs in a subshell
# shellcheck disable=SC2329
wallet_scan_sample() { :; }
# shellcheck disable=SC2329
rx() { [ "$FAIL_SCAN" = 0 ]; }
# shellcheck disable=SC2329
api_state() { printf '{"earnings":{"confirmed":{"reachable":true,"address_match":%s}}}' "$([ "$FAIL_ADDRESS" = 0 ] && echo true || echo false)"; }
# shellcheck disable=SC2329
wait_for() {
    echo "$1/$2" >>"$WORK/waits"
    shift 3
    "$@"
}
(recovery_ready "$WORK/source") >/dev/null 2>&1
assert_rc "a caught-up wallet that answers with the configured address passes" "$?" 0
assert_eq "the original 1200 s catch-up and 420 s dashboard waits are reused" "$(cat "$WORK/waits")" "$(printf '1200/15\n420/10')"
(FAIL_ADDRESS=1 recovery_ready "$WORK/source") >/dev/null 2>&1
assert_rc "a wallet that does not match the configured address fails" "$?" 1
(FAIL_SCAN=1 recovery_ready "$WORK/source") >/dev/null 2>&1
assert_rc "a wallet still scanning fails" "$?" 1

echo "== the runner's lock is verified only when the runner holds it =="
unset RIG_LOCK_PARENT_ACTOR RIG_LOCK_PARENT_NONCE
rig_lock_parent_verify() {
    echo verify >>"$LOG"
    return "${VERIFY_RC:-0}"
}
: >"$LOG"
recovery_lock_verify
assert_rc "without a parent lock there is nothing to verify" "$?" 0
assert_eq "and the verifier is not called" "$(cat "$LOG")" ""
RIG_LOCK_PARENT_ACTOR=runner:1 VERIFY_RC=0 recovery_lock_verify
assert_rc "a held lock that verifies passes" "$?" 0
RIG_LOCK_PARENT_ACTOR=runner:1 VERIFY_RC=1 recovery_lock_verify
assert_rc "a lock that no longer verifies fails" "$?" 1
RIG_LOCK_PARENT_NONCE=0123456789abcdef0123456789abcdef VERIFY_RC=1 recovery_lock_verify
assert_rc "a nonce alone also demands the proof" "$?" 1

echo "== the script entry point =="
out="$(bash "$HERE/lib/wallet-fixture-recovery.sh" lock-verify 2>/dev/null)"
assert_rc "lock-verify with no parent lock exits 0" "$?" 0
assert_eq "and prints nothing on stdout, which the verdict owns" "$out" ""
bash "$HERE/lib/wallet-fixture-recovery.sh" bogus >/dev/null 2>&1
assert_rc "an unknown action exits 2" "$?" 2
bash "$HERE/lib/wallet-fixture-recovery.sh" start >/dev/null 2>&1
assert_rc "start without a baseline checkout fails" "$?" 1

echo "== the Python entry point prints one fixed object and exits 1 on a refusal =="
RECOVERY="$HERE/lib/wallet_fixture_recovery.py"
export RIG_LOCK_FILE="$WORK/rig.lock"
out="$(printf '{}' | python3 "$RECOVERY" 2>/dev/null)"
rc=$?
assert_rc "a wrong argument count exits 1" "$rc" 1
assert_eq "and names only the reason" "$out" '{"schema": 1, "status": "REFUSED", "reason": "request"}'
request='{"schema": 1, "original_job": 12, "original_commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "recovery_issues": ["bench-ci#1"]}'
out="$(printf '%s' "$request" | python3 "$RECOVERY" "$WORK/baseline" "$WORK/snapshot" "$WORK/12" 2>/dev/null)"
rc=$?
assert_rc "a missing job directory exits 1" "$rc" 1
assert_eq "with a fixed reason and no path in it" "$out" '{"schema": 1, "status": "REFUSED", "reason": "evidence"}'

echo "selftest-wallet-recovery: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
