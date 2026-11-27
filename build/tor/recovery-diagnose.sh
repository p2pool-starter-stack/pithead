#!/bin/sh
# Read-only, cookie-authenticated evidence for the explicit host recovery command.
set -eu
cookie=$(xxd -p -c 256 "${TOR_COOKIE_FILE:-/var/lib/tor/control_auth_cookie}" | tr -d '\n')
[ "${#cookie}" -eq 64 ] || exit 1
case "$cookie" in *[!0-9a-fA-F]*) exit 1 ;; esac
reply=$(printf 'AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase status/circuit-established\r\nQUIT\r\n' "$cookie" |
    nc -w 3 127.0.0.1 9051) || exit 1
# Refuse missing, duplicate, unsuccessful or reordered replies. Never expose the cookie or reply.
printf '%s\n' "$reply" | tr -d '\r' | awk '
    NR == 1 { if ($0 != "250 OK") exit 1; next }
    /^250-status\/bootstrap-phase=/ {
        if (++bootstrap != 1 || completed) exit 1
        progress = 0; tag = 0
        for (i = 1; i <= NF; i++) {
            if ($i == "PROGRESS=95") progress++
            if ($i == "TAG=circuit_create") tag++
        }
        if (progress != 1 || tag != 1) exit 1
        next
    }
    /^250-status\/circuit-established=0$/ {
        if (++circuit != 1 || completed) exit 1
        next
    }
    /^250 OK$/ { if (++completed != 1 || bootstrap != 1 || circuit != 1) exit 1; next }
    /^250 closing connection$/ { if (!completed || ++closed != 1) exit 1; next }
    { exit 1 }
    END { if (NR < 4 || bootstrap != 1 || circuit != 1 || completed != 1) exit 1 }
'
printf 'bootstrap95-no-circuit\n'
