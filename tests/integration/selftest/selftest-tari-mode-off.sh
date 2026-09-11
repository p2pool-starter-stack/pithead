#!/usr/bin/env bash
#
# Self-test for the harness's tari.mode handling (#1855/#1929) — the THIRD value.
#
# THE TRAP THIS PINS. monero.mode has two values, tari.mode has three, and every place the harness
# decided "is the bundled Tari container expected" was written as `= "remote"`. That equality is
# correct for monero and silently wrong for tari: an "off" machine takes the ELSE branch, which is
# the LOCAL branch — so absent_services() left `tari` off the must-not-exist list (a leftover
# container would pass), and the onion assertion demanded a hidden service that onion_provisioning
# deliberately never mints (32-onion-provisioning.sh gates it on `== "local"`). #1905 fixed exactly
# this shape host-side (`== remote` -> `!= local` in the Tari preflight); these are its siblings.
#
# Pure logic only — no server, no docker — so it runs in CI with the rest of
# `make test-integration-selftest`, which is where a three-valued axis needs a guard that a live
# matrix run (manual, release-gated) cannot give it.
#
# These cases live in their own file rather than in selftest.sh because that file sits exactly on
# its recorded budget ceiling, and ceilings only go down.
#
# Run: tests/integration/selftest/selftest-tari-mode-off.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/scenarios.sh
source "$HERE/../scenarios.sh"

echo "== tari.mode=off: the third value the two-valued tests dropped (#1855/#1929) =="

cfg() { printf '{"monero":{"mode":"local"},"tari":{"mode":"%s"}}' "$1"; }
absent_for() { absent_services "$(cfg "$1")" | tr '\n' ' ' | sed 's/ $//'; }
expected_for() { expected_services "$(cfg "$1")" | tr '\n' ' ' | sed 's/ $//'; }

# 1. The defect itself: off must put `tari` on the must-not-exist list, exactly as remote does.
assert_eq "off lists the bundled tari as must-not-exist" "$(absent_for off)" "tari"
# The CONTROL that makes the row above mean something: remote already passed before the fix, so a
# green "off" alone could just as well be a test that matches everything.
assert_eq "remote lists it too (the arm that always worked)" "$(absent_for remote)" "tari"
assert_eq "local lists nothing — the node is supposed to be up" "$(absent_for local)" ""
# ...and the NEAR MISS that keeps the rule narrow: monero.mode has no third value, so nothing here
# may start treating a non-remote monero as absent.
assert_eq "a local monero is never listed absent" \
    "$(absent_services '{"monero":{"mode":"local"},"tari":{"mode":"off"}}' | tr '\n' ' ' | sed 's/ $//')" "tari"
assert_eq "a remote monero still is" \
    "$(absent_services '{"monero":{"mode":"remote"},"tari":{"mode":"local"}}' | tr '\n' ' ' | sed 's/ $//')" "monerod"

# 2. The other half of the same fact, from the opposite direction: off must not EXPECT the
#    container either. A list that both expects and forbids `tari` would make the pair vacuous.
assert_ne "off does not expect the bundled tari" "$(expected_for off)" "$(expected_for local)"
assert_contains "local DOES expect it (the control for the row above)" " $(expected_for local) " " tari "

# 3. The matrix carries an off scenario at all, and it carries no external-node override — the
#    whole point of this mode is that it needs nothing to point at.
assert_contains "the matrix has a tari.mode=off scenario" "$(scenario_names)" "tari-off-main-secure"
ovr="$(scenario_overrides tari-off-main-secure)"
# An EMPTY $ovr would sail through the absence check below — the shape that makes a negative
# assertion prove nothing. Establish the reading is real before reading an absence out of it.
assert_ne "the off scenario's overrides were actually read" "$ovr" ""
assert_contains "the off scenario actually sets tari.mode=off" "$ovr" "tari.mode=off"
# It must NOT pin dashboard.tari_required: render_env derives TARI_REQUIRED from the mode for off,
# and a scenario that set the flag by hand would prove the flag, not the derivation.
case "$ovr" in
*tari_required*) it_fail "the off scenario leaves tari_required to the host's derivation" "overrides pin it: $ovr" ;;
*) it_pass "the off scenario leaves tari_required to the host's derivation" ;;
esac # no assert_not_contains in this lib

echo ""
echo "selftest-tari-mode-off: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
