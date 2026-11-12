#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
: "${TMPDIR:=/tmp}"
T=$(mktemp -d "$TMPDIR/shellcheck-budget.XXXXXX")
trap 'rm -rf "$T"' EXIT

guard="$ROOT/scripts/lint/shellcheck-budget.sh"
label="$T/slow-file.sh"

fail() {
    printf 'selftest-shellcheck-budget: FAIL: %s\n' "$*" >&2
    exit 1
}

bash "$guard" 30 "$label" true || fail 'a command inside the budget must pass through'

rc=0
bash "$guard" 30 "$label" sh -c 'exit 3' || rc=$?
[ "$rc" -eq 3 ] || fail "a command failing inside the budget must keep its status, got $rc"

start=$SECONDS
rc=0
out=$(bash "$guard" 1 "$label" sleep 45678 2>&1) || rc=$?
elapsed=$((SECONDS - start))
[ "$rc" -ne 0 ] || fail 'a command past the budget must fail'
[ "$elapsed" -lt 10 ] || fail "a past-budget command was still running after ${elapsed}s"
! pgrep -f 'sleep 45678' >/dev/null || fail 'the past-budget command was not killed'
grep -Fq "$label" <<<"$out" || fail 'the budget failure must name the file'
grep -Fq 'budget' <<<"$out" || fail 'the budget failure must name the budget'
grep -Fq 'source=/dev/null' <<<"$out" || fail 'the budget failure must point at the source hint'

rc=0
bash "$guard" 0 "$label" true >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "a zero budget must be refused, got $rc"
rc=0
bash "$guard" "$label" true >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "a missing budget must be refused, got $rc"

printf 'selftest-shellcheck-budget: PASS\n'
