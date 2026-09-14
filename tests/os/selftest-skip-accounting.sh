#!/usr/bin/env bash
#
# Self-test for the OS battery's skip accounting (#2064).
#
# The counting and classifying logic (it_skip_leg/phase/scenario, the missing/by-design/covered
# buckets, the default-to-missing pessimism) is tests/integration/lib/skip-accounting.sh's own —
# tests/os/run.sh sources that file rather than re-implementing it, so its behaviour is already
# proven by tests/integration/selftest/selftest-skip-accounting.sh. Re-testing it here would only
# prove the same file agrees with itself.
#
# What is NOT proven anywhere else: that tests/os/run.sh still sources it (a silent drop would
# read as "no skips" rather than "no skip vocabulary"), that its summary renders the three
# buckets, and — the regression #1365/#1083 both existed to catch — that no cannot-apply site in
# tests/os leaves the harness through a bare `it_warn` or an invented class instead of the
# counted, classified helpers. Standalone, matched by `make test-integration-selftest`'s
# `tests/os/selftest*.sh` glob. No server, no bench, no rig.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# assert_eq/assert_ne/assert_contains/it_pass/it_fail — reused rather than re-spelled, same
# reasoning as sourcing skip-accounting.sh itself: two copies of an assertion helper is two
# places for them to drift apart.
# shellcheck source=tests/integration/lib.sh
source "$HERE/../integration/lib.sh"

echo "== tests/os/run.sh still sources the skip vocabulary and renders the three buckets =="
grep -q 'integration/lib/skip-accounting.sh' "$HERE/run.sh" &&
    it_pass "run.sh sources skip-accounting.sh" ||
    it_fail "run.sh no longer sources skip-accounting.sh" "a silent drop reads as 'no skips' instead of 'no skip vocabulary'"
for word in IT_SKIPPED_MISSING IT_SKIPPED_BY_DESIGN IT_SKIPPED_COVERED; do
    grep -q "$word" "$HERE/run.sh" &&
        it_pass "run.sh's summary renders $word" ||
        it_fail "run.sh's summary does not render $word" "the printed summary would drop a bucket"
done

echo "== census: no skip in tests/os may leave the harness through a bare it_warn =="
# Identical rules to tests/integration/selftest/selftest-skip-accounting.sh's census, applied to
# tests/os's own files. it_warn stays sanctioned for a genuine warning; only skip WORDING or the
# warn-then-return SHAPE is flagged, so a real degraded-input warning is left alone.
census_wording() { # <file> -> skip warnings that never reach a counter
    grep -n 'it_warn' "$1" |
        grep -Ei 'skipp(ed|ing)' |
        grep -v 'it_warn "SKIPPED scenario' |
        grep -v 'it_warn "▲ SKIPPED WHOLE PHASE' |
        grep -v 'it_warn "skipped leg'
}
census_shape() { # <file> -> warn-then-return-0 sites that are not counted skips
    awk '
        /it_warn/ { w = NR; t = $0; next }
        w && NF {
            if ($0 ~ /^[[:space:]]*return 0[[:space:]]*$/ && t !~ /--keep:/) print w ": " t
            w = 0
        }
    ' "$1"
}
census_class() { # <file> -> it_skip_* call sites whose trailing class argument is not one of the three
    grep -nE 'it_skip_(scenario|phase|leg) .*"[a-z-]+"[[:space:]]*$' "$1" |
        grep -vE '"(by-design|covered|missing)"[[:space:]]*$'
}
# Globbed, not enumerated — a file added later must be seen without editing this list. lib/*.sh
# and phases/*.sh are the two subdirectories; the top-level selftest-*.sh files are excluded by
# name — they stub and assert ON this wording, which would otherwise flag itself.
for f in "$HERE"/*.sh "$HERE"/lib/*.sh "$HERE"/phases/*.sh; do
    case "$(basename "$f")" in selftest-*.sh) continue ;; esac
    _stray="$(
        census_wording "$f"
        census_shape "$f"
    )"
    assert_eq "no uncounted skip survives in $(basename "$f")" "${_stray:-none}" "none"
    _badcls="$(census_class "$f")"
    assert_eq "no invented skip class in $(basename "$f")" "${_badcls:-none}" "none"
done

echo "== the census rules can actually fire =="
_tmp="$(mktemp)"
printf '%s\n' 'it_warn "skipping the rig dashboard legs (no stack)"' >"$_tmp"
assert_ne "the wording rule fires on a bare-warn skip (positive control)" "$(census_wording "$_tmp")" ""
printf '%s\n' '    it_warn "not applicable here"' '    return 0' >"$_tmp"
assert_ne "the shape rule fires on a warn-then-return with no skip wording (positive control)" "$(census_shape "$_tmp")" ""
printf '%s\n' '    it_skip_leg "some leg" "some reason" "bydesign"' >"$_tmp"
assert_ne "the class rule fires on a near-miss class (positive control)" "$(census_class "$_tmp")" ""
printf '%s\n' '    it_skip_leg "some leg" "some reason" "by-design"' >"$_tmp"
assert_eq "the class rule leaves a valid class alone (negative control)" "$(census_class "$_tmp")" ""
rm -f "$_tmp"

echo "selftest-skip-accounting (os): $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
