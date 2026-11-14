#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/require-complete-verdict.sh
. "$HERE/require-complete-verdict.sh"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
check() { # <flag> <missing> <expected-rc> [must-mention]
    local flag="$1" missing="$2" expected="$3" mention="${4:-}" out="" rc=0
    out=$(require_complete_verdict "$flag" "$missing") || rc=$?
    [ "$rc" = "$expected" ] || fail "flag=$flag missing=$missing returned $rc, want $expected"
    if [ "$expected" = 0 ]; then
        [ -z "$out" ] || fail "flag=$flag missing=$missing printed a verdict while satisfied: $out"
    else
        [ -n "$out" ] || fail "flag=$flag missing=$missing stayed silent while violated"
        printf '%s' "$out" | grep -qF 'require-complete' || fail "verdict does not name require-complete: $out"
        [ -z "$mention" ] || printf '%s' "$out" | grep -qF "$mention" ||
            fail "verdict does not name the count ($mention): $out"
    fi
    printf 'PASS: flag=%s missing=%s\n' "$flag" "$missing"
}
check 1 2 1 '2 row(s)'
check 1 12 1 '12 row(s)'
check 1 1 1 '1 row(s)'
check 1 0 0
check 0 2 0
check '' 2 0
check 1 '' 0
printf 'PASS: require_complete_verdict\n'
