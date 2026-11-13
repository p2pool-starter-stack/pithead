#!/usr/bin/env bash
endpoint_shown() {
    printf '%s' "$1" | jq -e --argjson live "$2" --arg chain "$3" --arg host "$4" '
        any(.preview_values[]?; .key == ($chain + ".remote.host") and .new == $host) or
        ($live[$chain].remote.host == $host and ($live[$chain].mode == "remote" or
            any(.preview_values[]?; .key == ($chain + ".mode") and .new == "remote")))' >/dev/null 2>&1
}
