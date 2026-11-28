#!/usr/bin/env bash
set -Eeuo pipefail
stage=initialization
trap 'printf "Tor heal dropcells guest failed at %s (line %s, exit %s)\n" "$stage" "$LINENO" "$?" >&2' ERR
FAULT_SEC=$((150 * 60))
SPACING_SEC=$((60 * 60))
TOLERANCE_SEC=60
cd /data/pithead
control=$(sed -n 's/^CONTROL_DIR=//p' .env)
data=$(sed -n 's/^TOR_DATA_DIR=//p' .env)
[ -d "$control" ] && [ -d "$data" ]
export TMPDIR="$control/work"
mkdir -p "$TMPDIR"
work=$(mktemp -d "$TMPDIR/tor-heal-dropcells.XXXXXX")
cp config.json "$work/config.json"
cp "$data/state" "$work/original-state"
table=pithead_test_dropcells
drop_rules() { nft delete table inet "$table" >/dev/null 2>&1 || true; }
restore() {
    local rc=$? restored=0 logfile
    trap - EXIT ERR
    drop_rules
    cp "$work/config.json" config.json || restored=1
    rm -f "$control/tor-newnym-budget"
    if docker compose stop tor >"$work/restore-stop.log" 2>&1; then
        cp "$work/original-state" "$data/state" || restored=1
    else
        restored=1
    fi
    docker compose start tor >"$work/restore-start.log" 2>&1 || restored=1
    ./pithead apply -y >"$work/restore.log" 2>&1 || restored=1
    if [ "$rc" != 0 ] || [ "$restored" != 0 ]; then
        for logfile in "$work"/*.log "$work"/timeline; do
            [ -f "$logfile" ] || continue
            printf 'Guest log: %s\n' "${logfile##*/}"
            tail -c 4096 "$logfile" || true
        done
    fi
    printf 'Guest restoration exit: %s; original exit: %s\n' "$restored" "$rc"
    if [ "$rc" = 0 ] && [ "$restored" != 0 ]; then rc=1; fi
    exit "$rc"
}
trap restore EXIT
tor_started() { docker inspect -f '{{.State.StartedAt}}' tor; }
tor_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' tor | awk '{print $1}'; }
stage=configure-enabled
jq '.tor.auto_heal=true' config.json >"$work/next-config"
cp "$work/next-config" config.json
./pithead apply -y >"$work/apply.log" 2>&1
docker exec tor /usr/local/bin/tor-healthcheck.sh
stage=install-drop-rules
ip=$(tor_ip)
[ -n "$ip" ]
nft add table inet "$table"
nft add chain inet "$table" dropcells '{ type filter hook forward priority -10; policy accept; }'
nft add rule inet "$table" dropcells ip saddr "$ip" tcp flags '& syn == 0' ct state established meta length gt 400 counter drop
started=$(date +%s)
echo "start $started" >"$work/timeline"
last_start=$(tor_started)
stage=observe-fault
open_seen=0
while [ "$(date +%s)" -lt $((started + FAULT_SEC)) ]; do
    now=$(date +%s)
    cur=$(tor_started)
    if [ "$cur" != "$last_start" ]; then
        echo "tor-restart $now" >>"$work/timeline"
        last_start=$cur
    fi
    if [ "$open_seen" = 0 ] && [ "$now" -ge $((started + 600)) ]; then
        established=$(docker exec tor sh -c 'netstat -tn 2>/dev/null | grep -c ESTABLISHED' || true)
        dropped=$(nft list chain inet "$table" dropcells | sed -n 's/.*counter packets \([0-9]*\).*/\1/p' | head -1)
        printf 'open-channel-sample established=%s dropped_packets=%s\n' "${established:-0}" "${dropped:-0}" >>"$work/timeline"
        if [ "${established:-0}" -ge 1 ] && [ "${dropped:-0}" -ge 1 ]; then open_seen=1; fi
    fi
    sleep 20
done
find "$control/results" -maxdepth 1 -name '*.json' -type f -exec \
    jq -r --argjson s "$started" 'select(.ts >= $s and (.action == "tor-newnym" or .action == "tor-dropguards" or .action == "tor-reset" or .action == "tor-recover")) | "\(.action) \(.status) \(.ts)"' {} \; 2>/dev/null | sort -k3 -n >>"$work/timeline" || true
cat "$work/timeline"
stage=verify-fault
[ "$open_seen" = 1 ]
grep -Eq '^tor-(newnym|dropguards) ' "$work/timeline"
disruptive=$(awk '$1 == "tor-restart" || $1 == "tor-reset" || ($1 == "tor-recover" && $2 == "applied") {print $NF}' "$work/timeline" | sort -n | uniq)
[ -n "$disruptive" ]
prev=""
for t in $disruptive; do
    if [ -n "$prev" ] && [ $((t - prev)) -lt $((SPACING_SEC - TOLERANCE_SEC)) ]; then
        printf 'disruptive rungs %s and %s are less than %s seconds apart\n' "$prev" "$t" "$SPACING_SEC" >&2
        exit 1
    fi
    prev=$t
done
stage=lift-fault
drop_rules
deadline=$(($(date +%s) + 30 * 60))
healthy=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker exec tor /usr/local/bin/tor-healthcheck.sh >/dev/null 2>&1; then
        healthy=1
        break
    fi
    sleep 30
done
[ "$healthy" = 1 ]
echo 'PASS: with data packets dropped on an open channel, disruptive rungs stay 60 minutes apart and Tor recovers once the fault lifts (#4280)'
