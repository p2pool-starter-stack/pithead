#!/bin/sh
set -eu
GUARD_STALL_MIN_UPTIME_SEC=300
case "${1:-}" in NEWNYM | GUARDS | STATUS) ;; *) exit 2 ;; esac
[ "$#" -eq 1 ] || exit 2
cookie=$(xxd -p -c 256 "${TOR_COOKIE_FILE:-/var/lib/tor/control_auth_cookie}" | tr -d '\n')
[ -n "$cookie" ] || exit 1
if [ "$1" = GUARDS ]; then
    state=$(printf 'AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase status/circuit-established uptime entry-guards\r\nQUIT\r\n' "$cookie" |
        nc -w 3 127.0.0.1 9051 | tr -d '\r') || exit 1
    printf '%s\n' "$state" | grep -qx '250 OK' || exit 1
    uptime=$(printf '%s\n' "$state" | sed -n 's/^250-uptime=//p')
    case "$uptime" in '' | *[!0-9]*) exit 1 ;; esac
    printf '%s\n' "$state" | grep -Eq '^250-status/bootstrap-phase=.* PROGRESS=95 TAG=circuit_create( |$)' || exit 3
    printf '%s\n' "$state" | grep -qx '250-status/circuit-established=0' || exit 3
    printf '%s\n' "$state" | grep -Eq '^\$[0-9A-Fa-f]{40}[^ ]* up( |$)' || exit 3
    [ "$uptime" -ge "$GUARD_STALL_MIN_UPTIME_SEC" ] || exit 3
    reply=$(printf 'AUTHENTICATE %s\r\nDROPGUARDS\r\n' "$cookie" |
        nc -w 3 127.0.0.1 9051) || exit 1
    [ "$(printf '%s\n' "$reply" | grep -c '^250 OK')" -eq 2 ] || exit 1
    printf 'DROPGUARDS accepted\n'
    exit 0
fi
if [ "$1" = STATUS ]; then
    reply=$(printf 'AUTHENTICATE %s\r\nGETINFO status/circuit-established circuit-status\r\nQUIT\r\n' "$cookie" |
        nc -w 3 127.0.0.1 9051) || exit 1
    printf '%s\n' "$reply" | tr -d '\r' | awk '
        NR == 1 { if ($0 != "250 OK") exit 1; next }
        /^250-status\/circuit-established=[01]$/ { split($0, a, "="); est = a[2]; next }
        /^250\+circuit-status=$/ { listing = 1; next }
        listing && $0 == "." { listing = 0; next }
        listing { if ($2 == "LAUNCHED" || $2 == "EXTENDED") pending++; else if ($2 == "BUILT" && $1 ~ /^[0-9]+$/) built = built (built == "" ? "" : ",") $1; next }
        END { if (est == "") exit 1; printf "circuit-established=%s pending=%d built=%s\n", est, pending + 0, built }
    '
    exit
fi
reply=$(printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\n' "$cookie" |
    nc -w 3 127.0.0.1 9051) || exit 1
[ "$(printf '%s\n' "$reply" | grep -c '^250 OK')" -eq 2 ] || exit 1
printf 'NEWNYM accepted\n'
