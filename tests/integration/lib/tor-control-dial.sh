# shellcheck shell=bash
#
# The "clearnet THROUGH Tor" control dial that pairs with every "direct clearnet dial is DROPPED"
# row (#270/#2059). Both harnesses build each attempt here, so attempt count and circuit
# isolation cannot drift: the e2e probe (egress-probe.sh) and the appliance leg
# (tests/os/appliance-egress-leg.sh).
#
# One stream through a random live exit fails now and then (#2619), so a failed control is retried.
# Attempt 1 is the original request, byte for byte, so recorded results stay comparable
# (bench-ci#812). Each later attempt names its own SOCKS user: Tor isolates streams by SOCKS auth
# (IsolateSOCKSAuth), so that attempt builds a fresh circuit. The DROP dial stays single-shot,
# because a timeout is its expected result.

# shellcheck disable=SC2034 # read by the harnesses that source this file
TOR_CONTROL_DIAL_ATTEMPTS=3

tor_control_dial_cmd() { # <docker|podman> <curl path> <socks host:port> <attempt, 1-based>
    local engine="$1" curl="$2" socks="$3" attempt="$4" limit=30 auth=""
    if [ "$attempt" -gt 1 ]; then
        limit=45
        auth="--proxy-user pithead-control-$$-$SECONDS-$attempt:x "
    fi
    printf '%s exec monerod %s -s -o /dev/null -m %s %s--socks5-hostname %s http://1.1.1.1/' \
        "$engine" "$curl" "$limit" "$auth" "$socks"
}
