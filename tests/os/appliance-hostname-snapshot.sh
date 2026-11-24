#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
hostname_snapshot_complete() {
    [ -n "$1" ] || return 1
    case "$1" in $'\t'* | *$'\t' | *$'\t\t'*) return 1 ;; esac
}

hostname_snapshot_diff() {
    local IFS=$'\x1f' i out="" cols=(kernel static env state cert avahi mdns card avahi-started)
    local -a bc ac
    read -ra bc <<<"${1//$'\t'/$'\x1f'}"
    read -ra ac <<<"${2//$'\t'/$'\x1f'}"
    for i in "${!cols[@]}"; do
        [ "${bc[i]:-}" = "${ac[i]:-}" ] ||
            out+="${out:+; }${cols[i]}: $(printf '%s' "${bc[i]:-empty}" | tr -s '[:space:]' ' ') -> $(printf '%s' "${ac[i]:-empty}" | tr -s '[:space:]' ' ')"
    done
    printf '%s' "${out:-none}"
}

hostname_stable_snapshot() {
    local tries=0 prev="" snap
    while [ "$tries" -lt 12 ]; do
        snap=$(hostname_runtime_snapshot "$1")
        if [ "$snap" = "$prev" ] && hostname_snapshot_complete "$snap"; then
            printf '%s' "$snap"
            return 0
        fi
        prev=$snap
        tries=$((tries + 1))
        sleep 5
    done
    printf '%s' "$snap"
    return 1
}

hostname_snapshot_unchanged() {
    local tries=0 matches=0 snap=""
    while [ "$tries" -lt 10 ]; do
        snap=$(hostname_runtime_snapshot "$1")
        if hostname_snapshot_complete "$snap"; then
            [ "$snap" = "$2" ] || {
                printf '%s' "$snap"
                return 1
            }
            matches=$((matches + 1))
            [ "$matches" -lt 4 ] || {
                printf '%s' "$snap"
                return 0
            }
        fi
        tries=$((tries + 1))
        sleep 5
    done
    printf '%s' "$snap"
    return 1
}

hostname_configured_host() {
    local tries=0 host=""
    while [ "$tries" -lt 3 ]; do
        host=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null | jq -r '.dashboard.host // empty')
        [ -z "$host" ] || break
        tries=$((tries + 1))
        sleep 5
    done
    printf '%s' "${host:-unreadable}"
}
