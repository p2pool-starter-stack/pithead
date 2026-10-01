# shellcheck shell=bash
# Bounded payout-wallet diagnostics. Docker's current State loses an OOM on restart;
# retain filtered recent events and cgroup samples while the prerequisite scan runs.
wallet_scan_sample() {
    rx "$(
        cat <<'WALLET_DIAGNOSTICS'
        date -u +%FT%TZ
        timeout 5 docker inspect --format "id={{.Id}} started={{.State.StartedAt}} exit={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} restarts={{.RestartCount}} health={{json .State.Health}}" wallet-rpc
        timeout 5 docker exec wallet-rpc sh -c '
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
            sed -n "/^rchar:/p; /^read_bytes:/p" /proc/1/io
            wallet_dir="${WALLET_DIR:-/home/ubuntu/wallets}"
            printf "wallet_cache_bytes=%s\n" "$(stat -c %s "$wallet_dir/payout-wallet" 2>/dev/null || echo unavailable)"
            printf "wallet_keys_bytes=%s\n" "$(stat -c %s "$wallet_dir/payout-wallet.keys" 2>/dev/null || echo unavailable)"
        '
        timeout 5 docker events --since 60s --until "$(date +%s)" --filter container=wallet-rpc --filter event=oom --filter event=die --filter event=start --filter event=restart --format '{{.Time}} action={{.Action}} exit={{index .Actor.Attributes "exitCode"}}'
WALLET_DIAGNOSTICS
    )" 2>&1 | redact
}

capture_wallet_diagnostics() { # <artifact directory>
    rx "timeout 5 docker inspect --format '{{json .State.Health}}' wallet-rpc" 2>&1 | redact >"$1/wallet-health.json" || true
    wallet_scan_sample >"$1/wallet-memory-events.txt" || true
}
