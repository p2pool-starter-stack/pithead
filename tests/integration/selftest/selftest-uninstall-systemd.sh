#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib/run-uninstall-systemd.sh
source "$HERE/../lib/run-uninstall-systemd.sh"
passes=0 failures=0
it_pass() { passes=$((passes + 1)); }
it_fail() { failures=$((failures + 1)); }
sleep() { :; }
rx() {
    case "$CASE" in
    clean) return 0 ;;
    active) echo "pithead-egress.service not-found active exited" ;;
    failed) echo "pithead-lan-check.service not-found failed failed" ;;
    unreadable) return 1 ;;
    esac
}
check() {
    local case_name="$1" want="$2" result=0
    CASE="$case_name" passes=0 failures=0
    verify_uninstall_systemd_state || result=$?
    [ "$result|$passes|$failures" = "$want" ] || {
        printf 'FAIL %s: %s|%s|%s\n' "$case_name" "$result" "$passes" "$failures"
        exit 1
    }
}
check clean '0|1|0'
check active '1|0|1'
check failed '1|0|1'
check unreadable '1|0|1'
CASE=clean passes=0 failures=0
arm_uninstall_systemd_state
[ "$passes|$failures" = '1|0' ]
CASE=unreadable passes=0 failures=0
if arm_uninstall_systemd_state; then exit 1; fi
[ "$passes|$failures" = '0|1' ]
printf 'PASS: uninstall systemd inventory and fixture failure paths\n'
