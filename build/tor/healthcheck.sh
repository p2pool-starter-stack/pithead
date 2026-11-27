#!/bin/sh
# Tor bootstrap healthcheck.
#
# The old check (`nc -z localhost 9050`) only confirmed the SOCKS port was *open*,
# which happens within ~1s — long before Tor has built circuits. Dependent services
# (tari, monerod) then started against a Tor that couldn't yet route, producing
# "Connectivity is OFFLINE" / "0/N successful peer syncs" on cold start.
#
# This instead asks Tor directly whether it has finished bootstrapping, via the
# cookie-authenticated control port, and is only healthy once it reports TAG=done.

set -eu

# The cookie path is fixed in the container. TOR_COOKIE_FILE is the test seam (#1372) — the same
# shape as entrypoint.sh's TORRC_OUT, and for the same reason: the shell suite has to drive this
# script for real, and it cannot write /var/lib/tor. Nothing sets it in production, so what ships
# is the default; the suite asserts that default is still spelled exactly this way.
COOKIE_FILE=${TOR_COOKIE_FILE:-/var/lib/tor/control_auth_cookie}
CONTROL_HOST=127.0.0.1
CONTROL_PORT=9051

# Control port not up yet, or cookie not written -> not ready.
[ -r "$COOKIE_FILE" ] || {
    printf 'Tor health: control cookie unavailable.\n'
    exit 1
}

# Cookie auth requires the raw 32-byte cookie hex-encoded in the AUTHENTICATE command.
COOKIE_HEX=$(xxd -p -c 256 "$COOKIE_FILE" 2>/dev/null | tr -d '\n')
case "$COOKIE_HEX" in
*[!0-9a-fA-F]* | "")
    printf 'Tor health: invalid control cookie.\n'
    exit 1
    ;;
esac
[ "${#COOKIE_HEX}" -eq 64 ] || {
    printf 'Tor health: invalid control cookie.\n'
    exit 1
}

# Keep only numeric progress and a bounded tag in health history. Never print the cookie,
# raw control reply or SUMMARY, which can contain relay addresses and other live values.
reply=$(printf 'AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase\r\nQUIT\r\n' "$COOKIE_HEX" |
    nc -w 3 "$CONTROL_HOST" "$CONTROL_PORT" 2>/dev/null) || {
    printf 'Tor health: control query failed.\n'
    exit 1
}
printf '%s\n' "$reply" | tr -d '\r' | awk '
    NR == 1 { authenticated = ($0 == "250 OK"); next }
    /^250-status\/bootstrap-phase=/ {
        if (++bootstrap != 1 || completed) invalid = 1
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^SUMMARY=/) break
            if ($i ~ /^PROGRESS=/) {
                if (++progress_count != 1 || $i !~ /^PROGRESS=[0-9]+$/ || length($i) > 12) invalid = 1
                progress = substr($i, 10)
            }
            if ($i ~ /^TAG=/) {
                if (++tag_count != 1 || $i !~ /^TAG=[a-z_]+$/ || length($i) > 68) invalid = 1
                tag = substr($i, 5)
            }
        }
        next
    }
    /^250 OK$/ { if (++completed != 1 || bootstrap != 1) invalid = 1; next }
    /^250 closing connection$/ { if (!completed || ++closed != 1) invalid = 1; next }
    { invalid = 1 }
    END {
        if (!authenticated) {
            print "Tor health: control authentication failed."
        } else if (invalid || bootstrap != 1 || completed != 1 || closed != 1 || progress_count != 1 || tag_count != 1 || progress + 0 > 100) {
            print "Tor health: bootstrap reply unavailable."
        } else if (progress + 0 == 100 && tag == "done") {
            exit 0
        } else {
            printf "Tor health: bootstrap progress=%s tag=%s.\n", progress, tag
        }
        exit 1
    }
'
