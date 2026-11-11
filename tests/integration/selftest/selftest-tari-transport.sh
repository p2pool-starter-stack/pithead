#!/usr/bin/env bash
set -uo pipefail

echo "== Tari transport cancellation cleanup =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-tari-stranded.sh
source "$HERE/lib/run-tari-stranded.sh"
scratch="$(mktemp -d)"
trap 'rm -r "$scratch"' EXIT
events="$scratch/events"
OUT_DIR="$scratch"
fault_rules_clear_all() { printf '%s\n' rules >>"$events"; }
rx() {
    printf '%s\n' "$1" >>"$events"
    cat >/dev/null
    return 0
}
(
    _TARI_TRANSPORT_FOREIGN_TRAP='printf "%s\n" original-trap >>"$events"'
    trap tari_transport_abort EXIT
    exit 23
)
assert_rc "transport exit cleanup preserves the failing exit code" "$?" 23
assert_eq "transport exit cleanup removes tagged faults before remote cleanup" "$(head -1 "$events")" rules
assert_contains "transport exit cleanup independently restores the remote log level" "$(cat "$events")" 'python3 - cleanup'
assert_eq "transport exit cleanup retains the prior exit trap" "$(tail -1 "$events")" original-trap

rx() {
    cat >/dev/null
    return 7
}
(
    _TARI_TRANSPORT_FOREIGN_TRAP='printf "%s\n" retained-trap >>"$events"'
    it_fail() { printf '%s\n' cleanup-failed >>"$events"; }
    trap tari_transport_abort EXIT
    exit 24
)
assert_rc "failed cancellation cleanup keeps the original failure code" "$?" 24
assert_contains "failed cancellation cleanup is reported" "$(cat "$events")" cleanup-failed
assert_eq "failed cancellation cleanup still invokes the prior trap" "$(tail -1 "$events")" retained-trap
printf 'passed: %s, failed: %s\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
