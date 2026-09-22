#!/usr/bin/env bash
# Regression for #2506: every emitted OS failure row increments run.sh's FAIL tally.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/appliance-config-approval-leg.sh
source "$HERE/appliance-config-approval-leg.sh"

FAIL=0
sensitive_live_config() { printf '{"dashboard":{"host":"fixture-box"}}'; }
hostname_runtime_snapshot() { printf unchanged; }
sensitive_preview() {
    APPROVAL_PREVIEW='{"id":"r1","status":"previewed"}'
    APPROVAL_REQUEST_ID=r1
}
dashboard_control_request() {
    case "$2" in *'"approve":true'*) printf '' ;; *) printf '{"status":"rejected","error":"typed payout confirmations"}' ;; esac
}
_ssh() { printf '%s\n' '{"id":"r1","status":"applied","approver":""}'; }
assert_appliance_hostname_identity() {
    bad "confirmed day-two hostname identity did not converge"
    return 1
}
ok() { :; }
bad() {
    FAIL=$((FAIL + 1))
    printf 'bad: %s\n' "$1"
}

output=$(mktemp)
trap 'rm -f "$output"' EXIT
phase_provision_sensitive_regressions fixture-user fixture-password >"$output" 2>&1
rows=$(grep -c '^bad:' "$output")
[ "$FAIL" -eq 2 ] && [ "$rows" -eq 2 ] || {
    cat "$output"
    exit 1
}
printf 'selftest-harness-failure-tally: %s emitted failures matched FAIL\n' "$rows"
