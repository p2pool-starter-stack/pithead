#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT
export IT_MODE=local IT_REMOTE_DIR="$TD"
# shellcheck source=tests/integration/lib/reset-restore-web.sh
source "$HERE/../lib/reset-restore-web.sh"

CALLS="$TD/calls"
echo 0 >"$TD/rc"
TICK_CHURNS=0
TICK_RC=0
rx() {
    local snippet="$1"
    printf '%s\n' "$snippet" >>"$CALLS"
    case "$snippet" in
    *'systemctl start pithead-address-watch.service'*)
        if [ "$TICK_CHURNS" = 1 ]; then
            echo $(($(cat "$TD/rc") + 1)) >"$TD/rc"
        fi
        return "$TICK_RC"
        ;;
    *'docker inspect'*) printf 'cid %s 1700000000 true healthy' "$(cat "$TD/rc")" ;;
    esac
}
sleep() { :; }
echo 1000 >"$TD/clock"
now_s() {
    local t
    t=$(cat "$TD/clock")
    t=$((t + 6))
    echo "$t" >"$TD/clock"
    printf '%s' "$t"
}

run_stable() {
    : >"$CALLS"
    rr_caddy_stable >"$TD/out" 2>&1
}

echo "== rr_caddy_stable fires one address-watch tick inside its window (#3987) =="
TICK_CHURNS=0 TICK_RC=0
run_stable
assert_rc "a stable Caddy across a fired address-watch tick passes the leg" "$?" "0"
assert_eq "the tick is fired while the window watches" "$(
    awk '/docker inspect/ && !seen++ {first=NR}
         /systemctl start pithead-address-watch.service/ {tick=NR}
         END {print (tick > first && tick < NR) ? "inside" : "outside"}' "$CALLS"
)" "inside"

TICK_CHURNS=1 TICK_RC=0
run_stable
assert_rc "a tick that restarts a current Caddy fails the leg (the #3987 double restart)" "$?" "1"

TICK_CHURNS=0 TICK_RC=5
run_stable
assert_rc "a box without the unit installed still passes the leg" "$?" "0"

if [ "$IT_FAIL" -gt 0 ]; then
    echo "selftest-caddy-stable-address-watch-tick: FAIL ($IT_FAIL)" >&2
    exit 1
fi
echo "selftest-caddy-stable-address-watch-tick: PASS"
