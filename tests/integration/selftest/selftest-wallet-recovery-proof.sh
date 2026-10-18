#!/usr/bin/env bash
# The lifecycle recovery proof: the Python plumbing, then the shell leg that runs it and grades the
# stack afterwards. No bench, Docker or wallet.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$(cd "$TEST_DIR/.." && pwd)"
python3 "$TEST_DIR/test-wallet-recovery-proof.py" || exit 1
python3 "$TEST_DIR/test-wallet-recovery-proof-command.py" || exit 1

# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-lifecycle-wallet-fixture.sh
source "$HERE/lib/run-lifecycle-wallet-fixture.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CALLS="$WORK/calls"
ADDRESS="4$(printf 'A%.0s' {1..94})"
FAILURE='{"failed_stage": "recover", "failure_reason": "recovery_refused", "log": "/scratch/recovery.log", "recovery_reason": "readiness", "restore_proven": false, "schema": 1, "detail": "MONERO_VIEW_KEY=jsonsecret"}'
TOOL_RC=0 TOOL_OUT='{"restore_proven": true, "schema": 1}' TAIL_OUT="" APPLIANCE_RC=1 STATUS_RC=0

# shellcheck disable=SC2329 # stubs for the collaborators the leg calls
rx() {
    echo "rx: $1" >>"$CALLS"
    case "$1" in
    'source ./pithead && is_appliance') return "$APPLIANCE_RC" ;;
    'python3 tests/integration/tools/prove-wallet-recovery.py .')
        printf '%s\n' "$TOOL_OUT"
        return "$TOOL_RC"
        ;;
    'tail -n 40 '*) printf '%s\n' "$TAIL_OUT" ;;
    esac
}
# shellcheck disable=SC2329
wait_status_ok() { echo "wait_status_ok $1" >>"$CALLS"; }
# shellcheck disable=SC2329
pithead() {
    echo "pithead $*" >>"$CALLS"
    return "$STATUS_RC"
}
# shellcheck disable=SC2329
assert_payout_wallet_ready() {
    echo "payout $*" >>"$CALLS"
    it_pass "payout gate stub"
}

drive() { # runs the leg with its counters isolated from this selftest's own
    local keep_pass="$IT_PASS" keep_fail="$IT_FAIL"
    IT_PASS=0 IT_FAIL=0 IT_SKIPPED_LEGS=0 IT_SKIPPED_BY_DESIGN=0 IT_SKIPPED_NAMES=""
    : >"$CALLS"
    prove_wallet_recovery >"$WORK/out" 2>&1
    LEG_RC=$? LEG_PASS=$IT_PASS LEG_FAIL=$IT_FAIL
    IT_PASS="$keep_pass" IT_FAIL="$keep_fail"
}

echo "== the leg runs the tool, then grades the stack the recovery started =="
drive
assert_rc "a proven recovery returns success" "$LEG_RC" 0
assert_eq "and records no failure" "$LEG_FAIL" 0
assert_eq "with the recovery, status and payout rows passing" "$LEG_PASS" 3
assert_eq "it asks for the checkout and then the stack, in order" "$(cat "$CALLS")" "$(printf '%s\n' \
    'rx: source ./pithead && is_appliance' \
    'rx: python3 tests/integration/tools/prove-wallet-recovery.py .' \
    'wait_status_ok 240' 'pithead status' 'payout confirmed Monero')"
STATUS_RC=1 drive
assert_eq "a stack that is not OK after the recovery fails the leg" "$LEG_FAIL" 1
assert_eq "and the payout gate still ran, so it is the status row that failed" "$(grep -c 'payout gate stub' "$WORK/out")" 1

echo "== a failed proof prints a redacted tail of the recovery log and stops =="
TOOL_RC=1 TOOL_OUT="$FAILURE" TAIL_OUT="MONERO_VIEW_KEY=viewsecret wallet $ADDRESS peer 203.0.113.9 refused" drive
assert_rc "a failed proof fails the leg" "$LEG_RC" 1
assert_eq "once, as the assertion row" "$LEG_FAIL" 1
assert_contains "the fixed stage and reason are printed" "$(cat "$WORK/out")" '"failed_stage": "recover"'
assert_contains "the recovery's own refusal reason is printed" "$(cat "$WORK/out")" '"recovery_reason": "readiness"'
assert_contains "the tail of its log is printed" "$(cat "$WORK/out")" "refused"
for secret in jsonsecret viewsecret "$ADDRESS" 203.0.113.9; do
    assert_eq "a secret value never reaches the job log: ${secret:0:6}" "$(grep -c -F -- "$secret" "$WORK/out")" 0
done
assert_eq "the log is read from the path the proof reported" "$(grep -c '^rx: tail -n 40 /scratch/recovery.log$' "$CALLS")" 1
assert_eq "the stack is not graded after a failed proof" "$(grep -cE '^(wait_status_ok|pithead|payout)' "$CALLS")" 0
TOOL_RC=1 TOOL_OUT='{"failed_stage": "configured_identity", "failure_reason": "validation_refused", "restore_proven": false, "schema": 1}' drive
assert_rc "a proof that failed before it had a log still fails" "$LEG_RC" 1
assert_eq "and no log is read" "$(grep -c '^rx: tail' "$CALLS")" 0
TOOL_RC=2 TOOL_OUT="" drive
assert_rc "a tool that cannot run fails the leg" "$LEG_RC" 1
assert_eq "as one failed row" "$LEG_FAIL" 1

echo "== an appliance records a named by-design skip and runs nothing =="
APPLIANCE_RC=0 drive
assert_rc "an appliance returns success" "$LEG_RC" 0
assert_eq "counts one by-design skip" "$IT_SKIPPED_BY_DESIGN" 1
assert_contains "names the recovery row and the channel" "$IT_SKIPPED_NAMES" "appliance channel"
assert_contains "and the issue" "$IT_SKIPPED_NAMES" "(#3483)"
assert_eq "no tool and no stack check ran" "$(wc -l <"$CALLS" | tr -d ' ')" 1

echo "selftest-wallet-recovery-proof: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
