# shellcheck shell=bash
#
# Builds each attempt of the "clearnet THROUGH Tor" control; retries use fresh circuits (#2619).

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
