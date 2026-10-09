# shellcheck shell=bash
# Only the stubbed XvB polling fixtures source this helper, inside a subshell.
_xvb_selftest_clock() { # <clock-file>; one simulated second per polling sleep
    XVBT_CLOCK="$1"
    printf 0 >"$XVBT_CLOCK" || return 1
    # The file survives command substitutions; date reads never consume the budget.
    date() {
        if [ "$*" = +%s ]; then cat "$XVBT_CLOCK"; else command date "$@"; fi
    }
    sleep() {
        local now
        now="$(cat "$XVBT_CLOCK")" || return 1
        printf '%s\n' "$((now + 1))" >"$XVBT_CLOCK"
    }
}
