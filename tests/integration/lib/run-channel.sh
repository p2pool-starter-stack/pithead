# shellcheck shell=bash
# Only a positively identified appliance may omit a checkout-only probe. A failed
# transport or CLI source leaves the ordinary probe binding, including missing tools.
skip_appliance_checkout_probe() { # <reason> <row names...>
    local reason="$1" row
    shift
    if ! rx 'source ./pithead && is_appliance' >/dev/null 2>&1; then
        return 1
    fi
    for row in "$@"; do
        it_skip_leg "$row" "appliance channel: $reason" by-design
    done
}
