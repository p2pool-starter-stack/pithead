#!/bin/sh
# Fixed, cookie-authenticated circuit refresh for the host control runner.
set -eu
case "${1:-}" in NEWNYM | STATUS) ;; *) exit 2 ;; esac
[ "$#" -eq 1 ] || exit 2
cookie=$(xxd -p -c 256 "${TOR_COOKIE_FILE:-/var/lib/tor/control_auth_cookie}" | tr -d '\n')
[ -n "$cookie" ] || exit 1
if [ "$1" = STATUS ]; then
    reply=$(printf 'AUTHENTICATE %s\r\nGETINFO status/circuit-established circuit-status\r\nQUIT\r\n' "$cookie" |
        nc -w 3 127.0.0.1 9051) || exit 1
    printf '%s\n' "$reply" | tr -d '\r' | awk '
        NR == 1 { if ($0 != "250 OK") exit 1; next }
        /^250-status\/circuit-established=[01]$/ { split($0, a, "="); est = a[2]; next }
        /^250\+circuit-status=$/ { listing = 1; next }
        listing && $0 == "." { listing = 0; next }
        listing { if ($2 == "LAUNCHED" || $2 == "EXTENDED") pending++; next }
        END { if (est == "") exit 1; printf "circuit-established=%s pending=%d\n", est, pending + 0 }
    '
    exit
fi
reply=$(printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\n' "$cookie" |
    nc -w 3 127.0.0.1 9051) || exit 1
[ "$(printf '%s\n' "$reply" | grep -c '^250 OK')" -eq 2 ] || exit 1
printf 'NEWNYM accepted\n'
