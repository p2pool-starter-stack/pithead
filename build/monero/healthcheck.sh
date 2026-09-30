#!/bin/sh
# monerod RPC, peer and height-progress health (#90, #2499).
#
# Reads the RPC credentials from the container's environment instead of taking them as
# arguments, so they are NOT baked into the compose `healthcheck.test` — where they would
# otherwise be readable via `docker inspect`. monerod serves RPC on localhost:18081 and requires
# digest auth when MONERO_NODE_USERNAME/MONERO_NODE_PASSWORD are set.
#
# Also fails a node with no outgoing peers for MONERO_HEALTH_PEERLESS_SEC (#2499): the RPC answers
# and `synchronized` stays true on an isolated node, so liveness alone reads green. The liveness call
# is the published, restricted listener; the peer counts are NOT read from it, because a restricted
# get_info answers 0 for them (#2921). They come from monerod-peers.sh, which reads the admin listener
# on this container's loopback. The first real zero is stamped in /tmp (tmpfs) and any peer clears it.
# A helper that gives no reading (listener down, restricted body, missing count) is "unavailable": no
# stamp or fabricated zero, and the healthcheck fails until visibility returns. Height must
# advance past its previous best within 30 minutes, even with peers; both clocks reset on restart. Every run prints one bounded line, which docker keeps in
# State.Health.Log for the dashboard: `pithead-monero-peers {"outgoing":N,...}` or
# `pithead-monero-peers unavailable`. No credential or raw response is printed.
set -eu

stamp=${MONERO_HEALTH_STAMP:-/tmp/monerod-peerless-since}
height_stamp=${MONERO_HEALTH_HEIGHT_STAMP:-/tmp/monerod-height-progress}
# Restricted get_info retains height. Bound and validate it before treating it as progress;
# never use its redacted connection counts. An RPC gap resets the height clock, as in the dashboard.
info=$(printf 'user = %s\n' "$(printf '%s:%s' "${MONERO_NODE_USERNAME:-}" "${MONERO_NODE_PASSWORD:-}" | jq -Rs .)" |
    curl -fsS --max-time 2 --max-filesize 65536 --digest --config - http://localhost:18081/get_info) 2>/dev/null || info=
height=$(printf '%s' "$info" | jq -er 'select(.status == "OK") | .height |
    select(type == "number" and . > 0 and . == floor and . <= 9007199254740991)' 2>/dev/null) || height=
case "$height" in
'' | *[!0-9]*)
    rm -f "$stamp" "$height_stamp"
    echo 'pithead-monero-peers unavailable'
    exit 1
    ;;
esac
# Host uptime is monotonic, like the dashboard clock. The PID-1 start ticks distinguish
# container runs even if a restart falls entirely between probes or tmpfs state survives it.
now=$(awk '{printf "%.0f", int($1)}' "${MONERO_HEALTH_UPTIME_FILE:-/proc/uptime}")
run=$(sed 's/.*) //' "${MONERO_HEALTH_RUN_FILE:-/proc/1/stat}" | awk '{print $20}')
case "$now:$run" in *[!0-9:]* | :* | *:) exit 1 ;; esac
previous_run='' best='' advanced=''
[ ! -s "$height_stamp" ] || read -r previous_run best advanced <"$height_stamp" || true
case "$previous_run:$best:$advanced" in
*[!0-9:]* | :* | *::* | *:) previous_run= ;;
esac
if [ "$previous_run" != "$run" ] || [ "${advanced:-0}" -gt "$now" ]; then
    [ -z "$previous_run" ] || rm -f "$stamp"
    best=$height advanced=$now
elif [ "$height" -gt "$best" ]; then
    best=$height advanced=$now
fi
printf '%s %s %s\n' "$run" "$best" "$advanced" >"$height_stamp"

peers=$("${MONERO_PEERS_HELPER:-/usr/local/bin/monerod-peers.sh}" 2>/dev/null) || peers=
out=$(printf '%s' "$peers" | sed -n 's/.*"outgoing": *\([0-9][0-9]*\).*/\1/p' | head -n 1)
if [ -z "$out" ]; then
    echo "pithead-monero-peers unavailable"
    rm -f "$stamp"
    exit 1
fi
echo "pithead-monero-peers $peers"
failed=0
if [ "$out" -gt 0 ]; then
    rm -f "$stamp"
else
    peer_now=$(date +%s)
    [ -s "$stamp" ] || echo "$peer_now" >"$stamp"
    since=$(cat "$stamp")
    if [ $((peer_now - since)) -ge "${MONERO_HEALTH_PEERLESS_SEC:-600}" ]; then
        echo "monerod has had 0 outgoing peers for $(((peer_now - since) / 60)) min" >&2
        failed=1
    fi
fi
if [ $((now - advanced)) -ge 1800 ]; then
    echo "monerod height $best has not moved for $(((now - advanced) / 60)) min" >&2
    failed=1
fi
exit "$failed"
