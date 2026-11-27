#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() {
    echo "selftest-evidence-redact: $1" >&2
    exit 1
}

export FAKE_M="4$(printf 'A%.0s' {1..94})"
export FAKE_T="12$(printf 'B%.0s' {1..89})"

# shellcheck source=tests/os/rollback-verdict.sh
source "$HERE/rollback-verdict.sh"

(
    bad_verdict="{\"verdict\":{\"outcome\":\"rolled_back\",\"blocking\":[\"detail: $FAKE_M\"]}}"
    out=$(rollback_verdict_check "$bad_verdict" "container dashboard" 2>&1) || true
    case "$out" in *"$FAKE_M"*) exit 2 ;; esac
    case "$out" in *"$FAKE_T"*) exit 3 ;; esac
) || fail "rollback_verdict_check leaked a payout address (exit $?)"

(
    bad_flag="{\"to\":\"2.0.2\",\"blocking\":[\"doctor: $FAKE_M\", \"x: $FAKE_T\"]}"
    out=$(rollback_blocking_check "$bad_flag" . "missing needle" 2>&1) || true
    case "$out" in *"$FAKE_M"*) exit 4 ;; esac
    case "$out" in *"$FAKE_T"*) exit 5 ;; esac
) || fail "rollback_blocking_check leaked a payout address (exit $?)"

(
    _ssh() { printf 'addr=%s  peer=%s\n' "$FAKE_M" "$FAKE_T"; }
    dest=$(mktemp)
    trap 'rm -f "$dest"' EXIT
    rollback_evidence "$dest"
    grep -qF "$FAKE_M" "$dest" && exit 6
    grep -qF "$FAKE_T" "$dest" && exit 7
    grep -qF '[redacted-address]' "$dest" || exit 8
) || fail "rollback_evidence leaked payout addresses in evidence file (exit $?)"

grep -q 'os_redact_addr | cut -c1-200' "$HERE/phases/update-dashboard.sh" ||
    fail "update-dashboard.sh: bad() calls missing os_redact_addr before cut -c1-200"

grep -q 'os_redact_addr | cut -c1-120' "$HERE/phases/update-dashboard.sh" ||
    fail "update-dashboard.sh: bad() missing os_redact_addr before cut -c1-120"

grep -q 'source.*redact-addr' "$HERE/rollback-verdict.sh" ||
    fail "rollback-verdict.sh does not source redact-addr.sh"

grep -q '| os_redact_addr_lines' "$HERE/rollback-verdict.sh" ||
    fail "rollback_evidence does not pipe through os_redact_addr_lines"

echo 'selftest-evidence-redact: PASS'
