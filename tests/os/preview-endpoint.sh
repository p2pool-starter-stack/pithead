#!/usr/bin/env bash
# A preview lists only changed values, so an endpoint the live config already uses counts as shown.
endpoint_shown() { # <preview-json> <live-config-json> <monero|tari> <host>
    printf '%s' "$1" | jq -e --argjson live "$2" --arg chain "$3" --arg host "$4" '
        any(.preview_values[]?; .key == ($chain + ".remote.host") and .new == $host) or
        ($live[$chain].mode == "remote" and $live[$chain].remote.host == $host)' >/dev/null 2>&1
}
