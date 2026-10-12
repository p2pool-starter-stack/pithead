#!/bin/sh
# Fixed, cookie-authenticated circuit refresh for the host control runner.
set -eu
[ "${1:-}" = NEWNYM ] && [ "$#" -eq 1 ] || exit 2
cookie=$(xxd -p -c 256 "${TOR_COOKIE_FILE:-/var/lib/tor/control_auth_cookie}" | tr -d '\n')
[ -n "$cookie" ] || exit 1
reply=$(printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\n' "$cookie" |
    nc -w 3 127.0.0.1 9051) || exit 1
[ "$(printf '%s\n' "$reply" | grep -c '^250 OK')" -eq 2 ] || exit 1
printf 'NEWNYM accepted\n'
