#!/usr/bin/env bash
# #2721: a slow host must not consume the stubbed guest's polling budget.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/appliance-xvb-routing-leg.sh
source "$HERE/appliance-xvb-routing-leg.sh"
regression_dir="$(mktemp -d)"
trap 'rm -rf "$regression_dir"' EXIT
printf 0 >"$regression_dir/wall"
# Each date read models two seconds of scheduling delay, including reads in $(...).
date() {
    if [ "$*" = +%s ]; then
        local now
        now=$(cat "$regression_dir/wall")
        printf '%s' "$((now + 2))" >"$regression_dir/wall"
        printf '%s\n' "$now"
    else
        command date "$@"
    fi
}
_xvb_self_test || exit 1
[ "$(date +%s)" = 0 ] || {
    echo 'xvb poll clock: fixture used or replaced the caller clock' >&2
    exit 1
}
(
    # shellcheck source=tests/os/xvb-selftest-clock.sh
    source "$HERE/xvb-selftest-clock.sh"
    _xvb_selftest_clock "$regression_dir/ticks"
    initial="$(date +%s)"
    child="$(
        sleep 99
        date +%s
    )"
    final="$(date +%s)"
    [ "$initial:$child:$final" = 0:1:1 ] || {
        echo 'xvb poll clock: time did not advance across a command substitution' >&2
        exit 1
    }
) || exit 1
echo 'XvB polling fixtures ignore host scheduling delays and preserve the caller clock'
