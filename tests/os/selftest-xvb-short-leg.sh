#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
OS_RUN_SUITE=1 SCRIPT_DIR="$HERE" HARNESS_WALLET=fixturewalletaddress0123456789
# shellcheck source=tests/os/appliance-xvb-routing-leg.sh
source "$HERE/appliance-xvb-routing-leg.sh"
# shellcheck source=tests/os/appliance-xvb-short-leg.sh
source "$HERE/appliance-xvb-short-leg.sh"
# shellcheck source=tests/os/xvb-selftest-clock.sh
source "$HERE/xvb-selftest-clock.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
_xvb_selftest_clock "$work/clock"
XVB_SHORT_STATE_TIMEOUT=4 XVB_PROXY_READY_TIMEOUT=4 XVB_ACTUATE_TIMEOUT=4

ok() { printf x >>"$work/pass"; }
bad() { printf x >>"$work/fail"; }
info() { :; }
it_skip_leg() { printf x >>"$work/skips"; }
_xvb_proxy_diag() { :; }
_xvb_guest_stderr() { :; }
approval_capture_restore_snapshot() { return 0; }
approval_restore_pending() {
    printf x >>"$work/restores"
    printf off >"$work/xvb"
    return "${RESTORE_RC:-0}"
}
_xvb_wait_for_tor() { [ "${TOR:-up}" = up ] || { printf starting && return 1; }; }
_xvb_real_tor_fetch_retry() { [ "${FETCH:-up}" = up ]; }
_xvb_wait_for_proxy_api() { return 0; }
_xvb_short_set_on() {
    printf x >>"$work/applies"
    [ "${APPLY_RC:-0}" = 0 ] || return 1
    printf on >"$work/xvb"
}
_xvb_actuate() { [ "$1" != XVB ] || [ "${ACTUATE:-up}" = up ]; }
_xvb_guest_python() { printf '%s' "$ROUTE"; }
_xvb_short_state() {
    if [ "$(cat "$work/xvb")" = on ]; then
        printf 'XVB\t%s\n' "${FAILS:-0}"
    else
        printf '%s\t0\n' "${BASE:-$_XVB_SHORT_OFF}"
    fi
}

good_route='{"xvb_url":"x.example:4247","donor":"fixturew","pools":[{"url":"x.example:4247","user":"fixturew","enabled":true,"tor":true},{"url":"p2pool:3333","user":"fixturewalletaddress0123456789","enabled":false,"tor":false}]}'

# <label> <want pass> <want fail> <want skips> <want applies> <want restores> [VAR=value ...]
case_run() {
    local label="$1" wp="$2" wf="$3" ws="$4" wa="$5" wr="$6" rc=0 got
    shift 6
    : >"$work/pass" && : >"$work/fail" && : >"$work/skips" && : >"$work/applies" && : >"$work/restores" && printf off >"$work/xvb"
    (
        for kv in "$@"; do export "${kv?}"; done
        phase_stack_xvb_short
    ) || rc=$?
    got="$(wc -c <"$work/pass" | tr -d ' ')/$(wc -c <"$work/fail" | tr -d ' ')/$(wc -c <"$work/skips" | tr -d ' ')/$(wc -c <"$work/applies" | tr -d ' ')/$(wc -c <"$work/restores" | tr -d ' ')"
    [ "$got" = "$wp/$wf/$ws/$wa/$wr" ] || {
        printf 'selftest-xvb-short-leg: FAIL %s: got pass/fail/skips/applies/restores %s want %s/%s/%s/%s/%s (rc %s)\n' \
            "$label" "$got" "$wp" "$wf" "$ws" "$wa" "$wr" "$rc" >&2
        exit 1
    }
}

ROUTE="$good_route"
case_run "a clean on and off leg passes four rows" 4 0 0 1 1
case_run "a guest with no Tor skips, never turns XvB on" 1 0 1 0 0 TOR=down
case_run "an unreachable XvB endpoint skips, never turns XvB on" 1 0 1 0 0 FETCH=down
case_run "XvB on by default is red before anything is changed" 0 1 0 0 0 "BASE=XVB"
case_run "a refused apply is red and still restores" 2 1 0 1 1 APPLY_RC=1
case_run "an XvB fetch error reads as not active, red, restored" 2 1 0 1 1 FAILS=2
case_run "a controller that cannot route to XvB is red and restored" 3 1 0 1 1 ACTUATE=down
case_run "a failed restore is red" 3 1 0 1 1 RESTORE_RC=1

for broken in \
    '{"xvb_url":"x.example:4247","donor":"fixturew","pools":[{"url":"x.example:4247","user":"fixturew","enabled":true,"tor":false}]}' \
    '{"xvb_url":"x.example:4247","donor":"fixturew","pools":[{"url":"p2pool:3333","user":"fixturew","enabled":true,"tor":true}]}' \
    '{"xvb_url":"x.example:4247","donor":"otherwal","pools":[{"url":"x.example:4247","user":"otherwal","enabled":true,"tor":true}]}' \
    '{"xvb_url":"x.example:4247","donor":"short","pools":[{"url":"x.example:4247","user":"short","enabled":true,"tor":true}]}' \
    '{"xvb_url":"x.example:4247","donor":"fixturew","pools":[{"url":"x.example:4247","user":"fixturew","enabled":true,"tor":true},{"url":"p2pool:3333","user":"fixturew","enabled":true,"tor":false}]}' \
    ''; do
    ROUTE="$broken"
    case_run "a wrong live route is red and restored: ${broken:-empty}" 3 1 0 1 1
done

echo 'selftest-xvb-short-leg: PASS'
