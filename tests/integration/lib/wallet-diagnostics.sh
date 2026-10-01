# shellcheck shell=bash
# Bounded payout-wallet diagnostics. Docker's current State loses an OOM on restart;
# retain filtered recent events and cgroup samples while the prerequisite scan runs.
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
    rx "timeout 5 docker inspect --format '{{json .State.Health}}' wallet-rpc" 2>&1 | redact >"$1/wallet-health.json" || true
    wallet_scan_sample >"$1/wallet-memory-events.txt" || true
}
