#!/usr/bin/env bash
set -Eeuo pipefail
stage=initialization
scrub() { sed -E 's/(--wallet[ =]|--merge-mine[ =][^ ]+ )[^ ]+/\1[redacted-address]/g; s/[1-9A-HJ-NP-Za-km-z]{90,}/[redacted-address]/g'; }
diagnose() {
    local stats
    stats=$(find /data -path '*/stats/local/p2p' -type f 2>/dev/null | head -n 1)
    printf 'diagnose: p2pool %s\n' "$(docker inspect p2pool --format '{{.State.Status}} started={{.State.StartedAt}} health={{.State.Health.Status}}' 2>&1 | head -c 300)" >&2
    printf 'diagnose: stats file %s\n' "${stats:-absent}" >&2
    [ -z "$stats" ] || jq -c 'del(.peers)' "$stats" 2>&1 | head -c 600 >&2
    printf '\ndiagnose: dashboard P2Pool log lines: %s\n' "$(docker logs --since "$epoch" dashboard 2>&1 | grep -c 'P2Pool')" >&2
    docker logs --tail 5 p2pool 2>&1 | scrub | head -c 800 >&2 || true
}
trap 'printf "P2Pool heal guest failed at %s (line %s, exit %s)\n" "$stage" "$LINENO" "$?" >&2; diagnose' ERR
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
control_path_restart() {
    docker exec -i dashboard python3 - <<'PY'
import asyncio

from mining_dashboard.client.docker.docker_control import DockerControl
from mining_dashboard.service.health import p2pool_heal as heal


class Clock:
    now = 0.0

    def __call__(self):
        return self.now


async def main():
    clock = Clock()
    healer = heal.P2PoolPeerHealer(DockerControl(), clock=clock)
    uptime = iter(range(1, 100))

    def stats():
        return {"p2p": {"out_peers": 0, "in_peers": 0, "uptime": next(uptime)}, "pool": {}}

    await healer.check(stats())
    clock.now = heal.ZERO_PEERS_AFTER_SEC + 1
    await healer.check(stats())


asyncio.run(main())
PY
}
stage=peerless-precondition
stats=$(find /data -path '*/stats/local/p2p' -type f 2>/dev/null | head -n 1)
if [ -z "$stats" ] || [ "$(jq -r '.uptime // 0' "$stats")" -le 0 ] || [ "$(peers)" -gt 0 ]; then
    stage=control-path
    before=$(started_at)
    for ((attempt = 0; attempt < 3; attempt++)); do
        running || docker start p2pool >/dev/null
        control_path_restart
        [ "$(started_at)" != "$before" ] && break
    done
    [ "$(started_at)" != "$before" ]
    echo 'PASS: the dashboard healer restarts the guest P2Pool through the appliance container control path (#4077)'
    exit 0
fi
stage=wait-p2pool-running
for ((attempt = 0; attempt < 60; attempt++)); do
    running && break
    sleep 10
done
running
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
