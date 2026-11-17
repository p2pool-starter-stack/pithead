# shellcheck shell=bash
e2e_sync_sample() {
    on_bench '
        set -o pipefail
        identity=$(timeout 5 docker inspect --format "{{.Id}} {{.State.StartedAt}}" dashboard) || exit 1
        started=$(date -d "${identity#* }" +%s) || exit 1
        now=$(date +%s) || exit 1
        metrics=$(curl -fsS --max-time 8 http://127.0.0.1:8000/metrics | head -c 65537) || exit 1
        [ "${#metrics}" -le 65536 ] || exit 1
        age=$(printf "%s\n" "$metrics" | awk '\''$1 == "pithead_snapshot_age_seconds" {count++; value=$2} END {if (count == 1) print value; else exit 1}'\'') || exit 1
        freshness=$(awk -v age="$age" -v uptime="$((now - started))" '\''BEGIN {
            if (age ~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/ && uptime > 0 && age + 0 < uptime)
                print "live"
            else print "stale"
        }'\'') || exit 1
        state=$(curl -fsS --max-time 8 http://127.0.0.1:8000/api/state | head -c 1048577) || exit 1
        [ "${#state}" -le 1048576 ] || exit 1
        st=$(printf "%s" "$state" | jq -r '\''"\(.sync.monero.state)/\(.sync.tari.state)"'\'') || exit 1
        [[ "$st" =~ ^(done|loading|syncing)/(done|loading|syncing)$ ]] || exit 1
        current=$(timeout 5 docker inspect --format "{{.Id}} {{.State.StartedAt}}" dashboard) || exit 1
        [ "$identity" = "$current" ] || exit 1
        printf "%s %s\n" "$st" "$freshness"
    '
}
