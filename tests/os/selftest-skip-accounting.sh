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
# assert_eq/assert_ne/assert_contains/it_pass/it_fail, and skip_census_wording/_shape/_class —
# reused rather than re-spelled, same reasoning as tests/os/run.sh sourcing skip-accounting.sh
# itself: two copies of an assertion or a census regex is two places for them to drift apart.
# shellcheck source=tests/integration/lib.sh
source "$HERE/../integration/lib.sh"
# shellcheck source=tests/integration/lib/skip-accounting.sh
source "$HERE/../integration/lib/skip-accounting.sh"

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
# skip_census_wording/_shape/_class are skip-accounting.sh's own (shared with
# tests/integration/selftest/selftest-skip-accounting.sh's identical census). it_warn stays
# sanctioned for a genuine warning; only skip WORDING or the warn-then-return SHAPE is flagged,
# so a real degraded-input warning is left alone.
#
# Globbed, not enumerated — a file added later must be seen without editing this list. lib/*.sh
# and phases/*.sh are the two subdirectories; the top-level selftest-*.sh files are excluded by
# name — they stub and assert ON this wording, which would otherwise flag itself.
for f in "$HERE"/*.sh "$HERE"/lib/*.sh "$HERE"/phases/*.sh; do
    case "$(basename "$f")" in selftest-*.sh) continue ;; esac
    _stray="$(
        skip_census_wording "$f"
        skip_census_shape "$f"
    )"
    assert_eq "no uncounted skip survives in $(basename "$f")" "${_stray:-none}" "none"
    _badcls="$(skip_census_class "$f")"
    assert_eq "no invented skip class in $(basename "$f")" "${_badcls:-none}" "none"
done

echo "== the census rules can actually fire =="
_tmp="$(mktemp)"
printf '%s\n' 'it_warn "skipping the rig dashboard legs (no stack)"' >"$_tmp"
assert_ne "the wording rule fires on a bare-warn skip (positive control)" "$(skip_census_wording "$_tmp")" ""
printf '%s\n' '    it_warn "not applicable here"' '    return 0' >"$_tmp"
assert_ne "the shape rule fires on a warn-then-return with no skip wording (positive control)" "$(skip_census_shape "$_tmp")" ""
printf '%s\n' '    it_skip_leg "some leg" "some reason" "bydesign"' >"$_tmp"
assert_ne "the class rule fires on a near-miss class (positive control)" "$(skip_census_class "$_tmp")" ""
printf '%s\n' '    it_skip_leg "some leg" "some reason" "by-design"' >"$_tmp"
assert_eq "the class rule leaves a valid class alone (negative control)" "$(skip_census_class "$_tmp")" ""
rm -f "$_tmp"

echo "== the REAL summary block out of run.sh renders the three buckets SEPARATELY =="
# Extracted rather than re-spelled, the same discipline as the integration selftest's summary()
# extraction: a re-implementation would agree with itself while the shipped file printed something
# else. One summed "N skipped" was the shape this replaced — losing a whole phase and losing one
# leg are not the same size of hole, and the integration summary has never conflated them.
SUMMARY_SRC="$(sed -n '/^printf .\\nos harness:/,/^fi$/p' "$HERE/run.sh")"
assert_contains "the extraction really is the summary block" "$SUMMARY_SRC" "os harness:"
render_summary() { # <scenarios> <phases> <legs> <missing> <by-design> <covered> -> its output
    (
        # Read by the eval'd summary block below, which shellcheck cannot see into.
        # shellcheck disable=SC2034
        PASS=7 FAIL=0
        IT_SKIPPED="$1" IT_SKIPPED_PHASES="$2" IT_SKIPPED_LEGS="$3"
        IT_SKIPPED_MISSING="$4" IT_SKIPPED_BY_DESIGN="$5" IT_SKIPPED_COVERED="$6"
        IT_SKIPPED_NAMES=""
        eval "$SUMMARY_SRC" 2>&1
    )
}
_rendered="$(render_summary 1 2 3 4 5 6)"
assert_contains "the summary reports scenarios, phases and legs as three separate buckets" \
    "$_rendered" "skipped: 1 scenarios, 2 phases, 3 legs"
assert_contains "the summary breaks those down by class, worded as the integration summary words it" \
    "$_rendered" "of which: 4 missing (an input would have run it), 5 by-design"
assert_contains "the breakdown names the covered bucket too" "$_rendered" "6 covered elsewhere"
assert_contains "the summary still reports the pass count" "$_rendered" "7 passed"
# A run that skipped nothing must not grow a hollow "did NOT run:" header with nothing under it.
case "$(render_summary 0 0 0 0 0 0)" in
*"did NOT run"*) it_fail "a run that skipped nothing prints no omissions block" "got a header with no rows" ;;
*) it_pass "a run that skipped nothing prints no omissions block" ;;
esac

echo "== leg 4 must have RUN before its skip may claim to cover pithead-boot (#2055 G1) =="
# The one piece of real branch logic this change adds, and the one a red run could turn into a
# lie: leg 4 returns early at a dozen gates, and on every one of them pithead-boot is as unproven
# as it was in legs 1-3. Extracted from phases/update.sh, both branches driven.
CLASSIFY_SRC="$(sed -n '/^    if \[ "\${LEG4_PITHEAD_BOOT_PROVED/,/^    fi$/p' "$HERE/phases/update.sh")"
assert_contains "the extraction really is the classification block" "$CLASSIFY_SRC" "it_skip_leg"
classify() { # <flag value, or empty for unset> -> "<by-design> <covered> <missing>"
    (
        # it_warn/it_err are lib/core.sh's in a real run; stubbed here because the subject is the
        # class that lands in the counters, not the warn text.
        it_warn() { :; }
        it_err() { :; }
        # Read by the eval'd classification block below, which shellcheck cannot see into.
        # shellcheck disable=SC2034
        [ -n "$1" ] && LEG4_PITHEAD_BOOT_PROVED="$1"
        eval "$CLASSIFY_SRC"
        printf '%s %s %s' "$IT_SKIPPED_BY_DESIGN" "$IT_SKIPPED_COVERED" "$IT_SKIPPED_MISSING"
    )
}
assert_eq "a leg 4 that proved the verdict earns the covered class" "$(classify 1)" "0 1 0"
assert_eq "a leg 4 that returned early is MISSING, never covered" "$(classify 0)" "0 0 1"
assert_eq "an unset flag is missing too — a red run cannot claim its own proof" "$(classify '')" "0 0 1"
# The reset is what stops an --phase all run inheriting a 1 from an earlier phase's leg 4.
grep -q '^    LEG4_PITHEAD_BOOT_PROVED=0' "$HERE/phases/update-dashboard.sh" &&
    it_pass "leg 4 resets the flag on entry, so a stale 1 cannot carry into the next phase" ||
    it_fail "leg 4 does not reset LEG4_PITHEAD_BOOT_PROVED on entry" "a later phase would inherit the last one's proof"
# ...and it may only be raised where the verdict actually lands.
assert_eq "the flag is raised in exactly one place" \
    "$(grep -c 'LEG4_PITHEAD_BOOT_PROVED=1' "$HERE/phases/update-dashboard.sh")" "1"

echo "== rows known before anything runs are recorded before anything runs =="
# #2064/ruling: a fact that is true of the guest whatever the run goes on to do must not be
# reported only by the runs that get far enough to reach it. The rig's dashboard-scoped legs are
# the case: a guest that dies at the image build enumerates the same row as one that finishes.
_rig_skip_line="$(grep -n 'it_skip_leg' "$HERE/phases/rig.sh" | head -1 | cut -d: -f1)"
_rig_first_fallible="$(grep -n '_build_image' "$HERE/phases/rig.sh" | head -1 | cut -d: -f1)"
[ -n "$_rig_skip_line" ] && [ -n "$_rig_first_fallible" ] &&
    [ "$_rig_skip_line" -lt "$_rig_first_fallible" ] &&
    it_pass "the rig by-design skip is recorded at phase entry, before the first fallible step" ||
    it_fail "the rig by-design skip sits after a step that can return early" \
        "skip at line ${_rig_skip_line:-none}, first _build_image at ${_rig_first_fallible:-none}"

echo "== legs 1-3 name what only another invocation proves, as missing (#2055 G1) =="
# by-design would book a real, reachable gap as accepted — #1083's failure mode one level up.
# Each of these three IS provable, by --phase provision or --phase all on this same box.
# Each row is checked with the class it is actually written with — the call spans two lines, so
# the class is on the continuation. A bare count would have passed on the leg-4 downgrade line,
# which is also (correctly) missing: the assertion has to name the row it is judging.
row_class() { # <row name> -> the class on that it_skip_leg call, or "none"
    grep -A1 -F "it_skip_leg \"$1" "$HERE/phases/update.sh" |
        sed -n 's/.*" \([a-z-]*\)$/\1/p' | head -1 | grep . || echo none
}
for row in "held-chain release" "boot-menu version repair" "/data-floor restore"; do
    assert_eq "the $row row is enumerated, classed missing" "$(row_class "$row")" "missing"
done

echo "selftest-skip-accounting (os): $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
