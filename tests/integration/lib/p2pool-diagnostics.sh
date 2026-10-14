# shellcheck shell=bash
# Capture the failing generation before the wrapper restores and replaces it.
capture_p2pool_diagnostics() { # <artifact directory>
    local dir="$1"
    mkdir -p "$dir" || return 1
    rx "$(
        cat <<'P2POOL_DIAGNOSTICS'
        date -u +%FT%TZ
        id=$(timeout --kill-after=2 5 docker inspect --format '{{.Id}}' p2pool) || {
            echo 'P2Pool container identity unavailable'; exit 1;
        }
        case "$id" in ''|*[!0-9a-f]*) echo 'P2Pool container identity invalid'; exit 1 ;; esac
        echo '=== candidate state ==='
        timeout --kill-after=2 5 docker inspect --format 'id={{.Id}} image={{.Image}} status={{.State.Status}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} exit={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} restarts={{.RestartCount}}' "$id" || echo 'P2Pool state unavailable'
        echo '=== candidate logs (last 200 lines, at most 65536 bytes) ==='
        timeout --kill-after=2 5 docker logs --timestamps --tail=200 "$id" 2>&1 | head -c 65536
        echo "logs_exit=${PIPESTATUS[0]} (141 can mean the byte cap was reached)"
        echo '=== candidate events (last 20 minutes, at most 16384 bytes) ==='
        events_end=$(date -u +%FT%TZ)
        timeout --kill-after=2 5 docker events --since=20m --until="$events_end" --filter "container=$id" --filter event=die --filter event=oom --filter event=restart --format 'time={{.Time}} event={{.Action}} exit={{index .Actor.Attributes "exitCode"}}' 2>&1 | head -c 16384
        echo "events_exit=${PIPESTATUS[0]} (141 can mean the byte cap was reached)"
P2POOL_DIAGNOSTICS
    )" 2>&1 | redact | tee "$dir/p2pool-crash.txt" | sed 's/^/p2pool-crash: /'
}
