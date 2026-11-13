#!/usr/bin/env bash
set -Eeuo pipefail
stage=initialization
trap 'printf "P2Pool heal guest failed at %s (line %s, exit %s)\n" "$stage" "$LINENO" "$?" >&2' ERR
cd /data/pithead
epoch=$(date +%s)
started_at() { docker inspect p2pool --format '{{.State.StartedAt}}'; }
running() { [ "$(docker inspect p2pool --format '{{.State.Running}}' 2>/dev/null || true)" = true ]; }
peers() {
    local stats
    stats=$(find /data -path '*/stats/local/p2p' -type f 2>/dev/null | head -n 1)
    [ -n "$stats" ] || {
        echo 0
        return
    }
    jq -r '(.connections // 0) + (.incoming_connections // 0)' "$stats"
}
heal_lines() {
    docker logs -t --since "$epoch" dashboard 2>&1 | grep 'P2Pool has had no peers for' || true
}
stage=wait-p2pool-running
for ((attempt = 0; attempt < 60; attempt++)); do
    running && break
    sleep 10
done
running
stage=peerless-precondition
if [ "$(peers)" -gt 0 ]; then
    echo 'SKIP: the guest P2Pool holds peers, so peer loss cannot be observed without a peerless guest'
    exit 77
fi
first_start=$(started_at)
stage=observe-restart
deadline=$((epoch + 50 * 60))
while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(started_at)" != "$first_start" ] && break
    sleep 30
done
[ "$(started_at)" != "$first_start" ]
[ "$(heal_lines | wc -l)" -ge 1 ]
echo 'PASS: the dashboard restarted a P2Pool that stayed peerless for 15 minutes (#4077)'
stage=running-after-restart
running
echo 'PASS: P2Pool is running after the dashboard restart (#4077)'
stage=backoff
deadline=$(($(date +%s) + 30 * 60))
while [ "$(date +%s)" -lt "$deadline" ] && [ "$(heal_lines | wc -l)" -lt 2 ]; do
    sleep 30
done
lines=$(heal_lines)
count=$(printf '%s\n' "$lines" | grep -c . || true)
[ "$count" -le 3 ]
[ "$count" -ge 2 ]
first=$(date -d "$(printf '%s\n' "$lines" | sed -n 1p | cut -d' ' -f1)" +%s)
second=$(date -d "$(printf '%s\n' "$lines" | sed -n 2p | cut -d' ' -f1)" +%s)
[ $((second - first)) -ge 1200 ]
running
echo 'PASS: a peerless P2Pool is restarted with backoff, stays within the daily cap and ends running (#4077)'
