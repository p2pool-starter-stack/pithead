#!/usr/bin/env bash
set -Eeuo pipefail
stage=initialization
epoch=$(date +%s)
table=pithead_t4157
redial_pattern='Restarting monerod to re-dial its peers through Tor'
cap_pattern='monerod restarts are held: all 3 automatic restarts'
peers_out() {
    docker inspect monerod --format '{{json .State.Health.Log}}' 2>/dev/null | jq -r '
        ((.[-1].Output // "") | split("\n") | map(select(startswith("pithead-monero-peers "))) | .[0] // "") as $line |
        if $line == "" then "" else ($line | ltrimstr("pithead-monero-peers ") | fromjson | .outgoing | tostring) end' 2>/dev/null || true
}
dashboard_log() { docker logs -t --since "$epoch" dashboard 2>&1; }
redial_lines() { dashboard_log | grep -F "$redial_pattern" || true; }
cap_lines() { dashboard_log | grep -F "$cap_pattern" || true; }
spent() { redial_lines | grep -c . || true; }
diagnose() {
    printf 'diagnose: monerod %s peers=%s\n' "$(docker inspect monerod --format '{{.State.Status}} started={{.State.StartedAt}}' 2>&1 | head -c 200)" "$(peers_out)" >&2
    printf 'diagnose: tor %s\n' "$(docker inspect tor --format '{{.State.Status}} started={{.State.StartedAt}} health={{.State.Health.Status}}' 2>&1 | head -c 200)" >&2
    printf 'diagnose: redial lines=%s cap lines=%s\n' "$(spent)" "$(cap_lines | grep -c . || true)" >&2
    dashboard_log | grep -E 'MonerodRedial|monerod re-dial|monerod restart' | tail -n 6 | cut -c1-300 >&2 || true
}
trap 'printf "monerod redial guest failed at %s (line %s, exit %s)\n" "$stage" "$LINENO" "$?" >&2; diagnose' ERR
unstrand() {
    local pid
    pid=$(docker inspect monerod --format '{{.State.Pid}}' 2>/dev/null || echo 0)
    if [ "$pid" -gt 0 ]; then nsenter -t "$pid" -n nft delete table inet "$table" >/dev/null 2>&1 || true; fi
}
restore() {
    local rc=$?
    trap - EXIT ERR
    local restored=0
    unstrand
    docker start tor >/dev/null 2>&1 || restored=1
    docker start monerod >/dev/null 2>&1 || restored=1
    printf 'Guest restoration exit: %s; original exit: %s\n' "$restored" "$rc"
    if [ "$restored" != 0 ]; then rc=1; fi
    exit "$rc"
}
trap restore EXIT
trap 'exit 143' TERM INT HUP
cd /data/pithead
started_at() { docker inspect "$1" --format '{{.State.StartedAt}}'; }
running() { [ "$(docker inspect "$1" --format '{{.State.Running}}' 2>/dev/null || true)" = true ]; }
audit_rows() {
    docker exec -i dashboard python3 -I - "$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import sqlite3
import sys

import mining_dashboard.config.config as config

db = sqlite3.connect(f"file:{config.DB_FILE_PATH}?mode=ro", uri=True)
rows = db.execute(
    "SELECT status, keys FROM audit_events WHERE actor = 'monerod-redial' "
    "AND action = 'restart' AND ts >= ? ORDER BY ts",
    (sys.argv[1],),
).fetchall()
for status, keys in rows:
    print(status, keys)
PY
}
wait_for() {
    local deadline=$((SECONDS + $1))
    shift
    while [ "$SECONDS" -lt "$deadline" ]; do
        "$@" && return 0
        sleep 15
    done
    return 1
}
must_not() {
    if "$@"; then return 1; fi
}
monerod_running() { running monerod; }
has_peers() {
    local n
    n=$(peers_out)
    [ -n "$n" ] && [ "$n" -gt 0 ]
}
no_peers() { [ "$(peers_out)" = 0 ]; }
monerod_restarted() { [ "$(started_at monerod)" != "$1" ]; }
tor_healthy() { [ "$(docker inspect tor --format '{{.State.Health.Status}}' 2>/dev/null || true)" = healthy ]; }
cap_announced() { [ -n "$(cap_lines)" ]; }
strand() {
    local pid prefix
    pid=$(docker inspect monerod --format '{{.State.Pid}}')
    prefix=$(docker inspect monerod --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^NETWORK_PREFIX=//p')
    [ "$pid" -gt 0 ] || false
    [ -n "$prefix" ] || false
    nsenter -t "$pid" -n nft -f - <<NFT
add table inet $table
add chain inet $table out { type filter hook output priority 0; policy accept; }
add rule inet $table out ip daddr $prefix.25 tcp dport 9050 reject with tcp reset
NFT
}
recover() {
    monerod_running
    wait_for 1500 has_peers
}
stage=tools
command -v nsenter >/dev/null || false
command -v nft >/dev/null || false
stage=precondition
wait_for 1800 monerod_running || exit 77
wait_for 1800 has_peers || exit 77
p2pool_start=$(started_at p2pool)
mdb=$(find /data -path '*/lmdb/data.mdb' -type f 2>/dev/null | head -n 1)
[ -n "$mdb" ]
mdb_inode=$(stat -c %i "$mdb")
wallet=$(jq -r '.monero.wallet_address' config.json)
stage=control-path
before=$(started_at monerod)
docker exec -i dashboard python3 -I - <<'PY'
import asyncio

from mining_dashboard.client.docker.docker_control import DockerControl
from mining_dashboard.service.health.monerod_redial import MonerodRedial

asyncio.run(MonerodRedial(DockerControl())._restart(0.0, "peerless"))
PY
monerod_restarted "$before"
echo 'PASS: the dashboard restarts monerod through the appliance container control path (#4157)'
stage=recover-after-control-path
recover
stage=tor-restart-strand
before=$(started_at monerod)
tor_before=$(started_at tor)
strand
wait_for 900 no_peers
stage=tor-restart
docker restart tor >/dev/null
[ "$(started_at tor)" != "$tor_before" ]
wait_for 600 tor_healthy
stage=tor-restart-redial
wait_for 900 monerod_restarted "$before"
[ "$(spent)" -eq 1 ]
audit_rows | grep -q '^applied monerod tor-start$'
stage=tor-restart-recovery
recover
echo 'PASS: monerod stranded across a Tor restart outside the healer is re-dialled once Tor is healthy and returns to outgoing peers (#4157)'
while [ "$(spent)" -lt 3 ]; do
    stage=peerless-strand
    wait_for 900 has_peers
    before=$(started_at monerod)
    n=$(spent)
    strand
    wait_for 900 no_peers
    if [ "$n" -ge 1 ]; then
        stage=cooldown-hold
        last=$(date -d "$(redial_lines | tail -n 1 | cut -d' ' -f1)" +%s)
        while [ "$(date +%s)" -lt $((last + 1740)) ]; do
            must_not monerod_restarted "$before"
            [ "$(spent)" -eq "$n" ]
            sleep 15
        done
        echo "PASS: a second strand inside the cooldown does not restart monerod again (restart $n held) (#4157)"
    fi
    stage=peerless-restart
    wait_for 1500 monerod_restarted "$before"
    [ "$(spent)" -eq $((n + 1)) ]
    audit_rows | tail -n 1 | grep -q '^applied monerod '
    stage=peerless-recovery
    recover
    echo "PASS: a peerless monerod is restarted once, audited and recovers to outgoing peers (restart $((n + 1)) of 3) (#4157)"
done
stage=daily-cap
wait_for 900 has_peers
before=$(started_at monerod)
strand
wait_for 900 no_peers
wait_for 1500 cap_announced
sleep 300
must_not monerod_restarted "$before"
[ "$(spent)" -eq 3 ]
[ "$(cap_lines | grep -c .)" -eq 1 ]
echo 'PASS: the daily cap holds a fourth restart and is announced once (#4157)'
stage=safety
unstrand
[ "$(started_at p2pool)" = "$p2pool_start" ]
[ "$(stat -c %i "$mdb")" = "$mdb_inode" ]
[ "$(jq -r '.monero.wallet_address' config.json)" = "$wallet" ]
echo 'PASS: P2Pool, the chain data and the payout identity are untouched (#4157)'
