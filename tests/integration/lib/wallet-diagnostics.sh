# shellcheck shell=bash
# Bounded payout-wallet diagnostics. Docker's current State loses an OOM on restart;
# retain filtered recent events and cgroup samples while the prerequisite scan runs.
# Read the retained wallet log locally on the box; emit labels/counts only.
# The generic final 200-line log tail loses startup under transaction-warning volume.
wallet_startup_sample() {
    rx "$(
        cat <<'WALLET_STARTUP_DIAGNOSTICS'
        timeout 5 bash <<'WALLET_STARTUP'
set -o pipefail
docker logs --timestamps wallet-rpc 2>&1 | awk '
    function stage(name) { if (!seen[name]++) print "wallet_startup_stage=" name }
    /Opening existing view-only payout wallet/ { stage("entrypoint_reopen") }
    /Creating view-only payout wallet/ { stage("entrypoint_create") }
    /Loading wallet\.\.\./ { stage("loading") }
    /Loaded wallet keys file, with public address:/ { stage("keys_loaded") }
    /wallet cache missing:/ { stage("cache_missing") }
    /Failed to open portable binary, trying unportable/ { stage("cache_format_fallback") }
    /Wallet initialization failed:/ { stage("initialization_failed") }
    /Initial refresh failed:/ { stage("initial_refresh_failed") }
    /Starting wallet RPC server/ { stage("rpc_started") }
    /Detaching blockchain on height [0-9]+/ { height=$0; sub(/^.*Detaching blockchain on height /, "", height); sub(/[^0-9].*$/, "", height); detach=height }
    /Re-processing wallet.*starting from height [0-9]+/ { height=$0; sub(/^.*starting from height /, "", height); sub(/[^0-9].*$/, "", height); rescan=height }
    /Transaction extra has unsupported format:/ { processing++ }
    /wallet_numeric_progress kind=[0-4] count=[0-9]+$/ {
        numeric=$0; sub(/^.*wallet_numeric_progress /, "", numeric);
        print "wallet_numeric_progress " numeric
    }
    END {
        printf "wallet_log_transaction_format_warnings=%d\n", processing;
        printf "wallet_log_detach_height=%s wallet_log_rescan_from_height=%s\n", detach=="" ? "unavailable" : detach, rescan=="" ? "unavailable" : rescan
    }
'
WALLET_STARTUP
        printf 'wallet_startup_log_exit=%s\n' "$?"
WALLET_STARTUP_DIAGNOSTICS
    )" 2>&1 | redact
}

wallet_scan_sample() {
    rx "$(
        cat <<'WALLET_DIAGNOSTICS'
        date -u +%FT%TZ
        timeout 5 docker inspect --format "id={{.Id}} started={{.State.StartedAt}} exit={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} restarts={{.RestartCount}} health={{json .State.Health}}" wallet-rpc
        timeout 5 docker exec -i wallet-rpc sh <<'WALLET_SAMPLE'
            for f in memory.current memory.peak memory.max memory.events; do
                if [ -r "/sys/fs/cgroup/$f" ]; then
                    echo "$f:"; cat "/sys/fs/cgroup/$f"
                fi
            done
            for f in memory.usage_in_bytes memory.max_usage_in_bytes memory.limit_in_bytes memory.failcnt; do
                if [ -r "/sys/fs/cgroup/memory/$f" ]; then
                    echo "$f:"; cat "/sys/fs/cgroup/memory/$f"
                fi
            done
            sed -n "/^VmRSS:/p; /^VmHWM:/p; /^Threads:/p" /proc/1/status
            sed -n "/^rchar:/p; /^read_bytes:/p; /^wchar:/p; /^write_bytes:/p" /proc/1/io
            # Strip comm through its last closing parenthesis before indexing stat fields.
            # Emit only state/counters: never command lines, environments or wallet contents.
            awk '{ sub(/^.*\) /, ""); if ($1 ~ /^[RSDTtZXIP]$/ && $12 ~ /^[0-9]+$/ && $13 ~ /^[0-9]+$/ && $20 ~ /^[0-9]+$/)
                { printf "process_state=%s cpu_user_ticks=%s cpu_system_ticks=%s process_start_ticks=%s\n", $1, $12, $13, $20; seen=1 } }
                END { if (!seen) print "process_cpu=unavailable" }' /proc/1/stat 2>/dev/null || echo "process_cpu=unavailable"
            printf "process_wait_channel=%s\n" "$(cat /proc/1/wchan 2>/dev/null || echo unavailable)"
            probe_height() {
                # Pinned Monero emits these complete, ordered JSON-RPC responses.
                # Reject errors, nesting and unknown shapes instead of guessing a height.
                case "$3" in
                    get_height) result="{\"height\":\\(0\\|[1-9][0-9]*\\)}" ;;
                    get_block_count) result="{\"count\":\\(0\\|[1-9][0-9]*\\),\"status\":\"OK\",\"untrusted\":\\(true\\|false\\)}" ;;
                esac
                response="$(curl -fsS --digest --max-time 1 -u "$2" \
                    -H "Content-Type: application/json" \
                    -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"$3\"}" "$1" 2>/dev/null)" || return 0
                printf '%s\n' "$response" |
                    # Preserve string contents and whitespace within scalar tokens.
                    awk '{ body=body $0 "\n" }
                        END { n=split(body, part, "\""); for (i=1; i<=n; i++) {
                            if (i%2) {
                                gsub(/[[:space:]]*:[[:space:]]*/, ":", part[i]);
                                gsub(/[[:space:]]*,[[:space:]]*/, ",", part[i]);
                                gsub(/[[:space:]]*[{][[:space:]]*/, "{", part[i]);
                                gsub(/[[:space:]]*[}][[:space:]]*/, "}", part[i]);
                                gsub(/^[[:space:]]+|[[:space:]]+$/, "", part[i]);
                            }
                            printf "%s%s", i==1 ? "" : "\"", part[i]
                        } print "" }' | sed -n "s/^{\"id\":\"0\",\"jsonrpc\":\"2.0\",\"result\":$result}$/\\1/p"
            }
            wallet_h="$(probe_height http://localhost:18082/json_rpc "${WALLET_RPC_USERNAME:-wallet}:${WALLET_RPC_PASSWORD:-}" get_height)"
            daemon_h="$(probe_height "http://${MONERO_NODE_HOST:-127.0.0.1}:${MONERO_RPC_PORT:-18081}/json_rpc" "${MONERO_NODE_USERNAME:-}:${MONERO_NODE_PASSWORD:-}" get_block_count)"
            printf "sample_wallet_height=%s sample_daemon_height=%s\n" "${wallet_h:-unavailable}" "${daemon_h:-unavailable}"
            wallet_dir="${WALLET_DIR:-/home/ubuntu/wallets}"
            printf "wallet_cache_bytes=%s\n" "$(stat -c %s "$wallet_dir/payout-wallet" 2>/dev/null || echo unavailable)"
            printf "wallet_keys_bytes=%s\n" "$(stat -c %s "$wallet_dir/payout-wallet.keys" 2>/dev/null || echo unavailable)"
WALLET_SAMPLE
        timeout 5 docker events --since 60s --until "$(date +%s)" --filter container=wallet-rpc --filter event=oom --filter event=die --filter event=start --filter event=restart --format '{{.Time}} action={{.Action}} exit={{index .Actor.Attributes "exitCode"}}'
WALLET_DIAGNOSTICS
    )" 2>&1 | redact
}

capture_wallet_diagnostics() { # <artifact directory>
    wallet_startup_sample >"$1/wallet-startup.txt" || true
    rx "timeout 5 docker inspect --format '{{json .State.Health}}' wallet-rpc" 2>&1 | redact >"$1/wallet-health.json" || true
    wallet_scan_sample >"$1/wallet-memory-events.txt" || true
}
