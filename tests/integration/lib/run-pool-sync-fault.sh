# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

# Run in one target shell so EXIT/INT/TERM restoration covers every failed assertion.
p2pool_sidechain_sync_snippet() {
    cat <<'PROBE'
    set -euo pipefail
    file=$1/stats/pool/stats
    scratch=$(mktemp -d "${TMPDIR:?runner scratch required}/pithead-p2pool-sync.XXXXXX")
    backup=$scratch/original
    saved=false
    restart=false
    cleanup() {
        rc=$?
        trap - EXIT INT TERM
        restored=true
        if [ "$saved" = true ]; then
            if ! sudo -n cp -p -- "$backup" "$file" || ! sudo -n cmp -s -- "$backup" "$file"; then
                restored=false
                rc=1
            fi
        fi
        if [ "$restart" = true ]; then
            if ! docker compose start p2pool >/dev/null 2>&1 ||
                ! docker compose ps --services --status running | grep -Fxq p2pool; then
                restored=false
                rc=1
            fi
        fi
        if [ "$saved" = true ] && [ "$restored" = true ]; then
            printf '%s\n' 'p2pool-sync: original stats restored and p2pool running'
            sudo -n rm -rf -- "$scratch"
        else
            printf '%s\n' 'p2pool-sync: preparation or restoration failed' >&2
            # Preserve the backup for diagnosis if restoration failed.
            [ "$saved" = true ] || rm -rf -- "$scratch"
        fi
        exit "$rc"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    restart=true
    docker compose stop p2pool >/dev/null 2>&1
    sudo -n cp -p -- "$file" "$backup"
    saved=true
    printf '%s\n' '{"pool_statistics":{"hashRate":10000,"miners":870,"totalHashes":400000,"totalBlocksFound":50,"pplnsWeight":500000,"pplnsWindowSize":2160,"sidechainDifficulty":100000,"sidechainHeight":3}}' |
        sudo -n tee "$file" >/dev/null
    wait_sync() {
        local expected=$1 height=$2 deadline state
        deadline=$(($(date +%s) + 90))
        while :; do
            if state=$(curl -fsS --max-time 10 http://127.0.0.1:8000/api/state) &&
                jq -e --argjson expected "$expected" --argjson height "$height" \
                    '.pool.syncing == $expected and .pool.sidechain_height == $height' <<<"$state" >/dev/null &&
                sudo -n cat "$file" | jq -e --argjson height "$height" \
                    '.pool_statistics.sidechainHeight == $height' >/dev/null; then
                return 0
            fi
            [ "$(date +%s)" -lt "$deadline" ] || return 1
            sleep 3
        done
    }
    wait_sync true 3
    printf '%s\n' 'p2pool-sync: bootstrap syncing=true with raw height 3'
    curl -fsS --max-time 10 -o "$scratch/overview.mjs" http://127.0.0.1:8000/static/app/overview.mjs
    grep -Fq 'P2Pool is syncing its sidechain' "$scratch/overview.mjs"
    printf '%s\n' 'p2pool-sync: served overview contains sidechain sync message'
    sudo -n cat "$file" | jq '.pool_statistics.sidechainHeight = 14973049 |
        .pool_statistics.sidechainDifficulty = 25000000 | .pool_statistics.hashRate = 2500000' >"$scratch/synced"
    sudo -n tee "$file" <"$scratch/synced" >/dev/null
    wait_sync false 14973049
    printf '%s\n' 'p2pool-sync: synced stats clear syncing=false'
PROBE
}

fault_p2pool_sidechain_sync() {
    local pdir out rc
    pdir=$(env_on_box P2POOL_DATA_DIR)
    if [ -z "$pdir" ]; then
        it_fail "P2Pool sidechain sync fixture has a data dir (#3249)" "P2POOL_DATA_DIR is missing"
        return
    fi
    it_step "fault: inject P2Pool's initial sidechain stats while its writer is stopped (#3249)…"
    rc=0
    out=$(p2pool_sidechain_sync_snippet | rx "bash -s -- $(quote_arg "$pdir")" --stdin 2>&1) || rc=$?
    out=$(printf '%s\n' "$out" | redact)
    printf '%s\n' "$out" >"$OUT_DIR/p2pool-sidechain-sync.log"
    assert_rc "P2Pool sidechain sync fault and restoration (#3249)" "$rc" 0
    assert_contains "P2Pool bootstrap stats report syncing at raw height 3 (#3249)" "$out" \
        'p2pool-sync: bootstrap syncing=true with raw height 3'
    assert_contains "served overview explains P2Pool sidechain sync (#3249)" "$out" \
        'p2pool-sync: served overview contains sidechain sync message'
    assert_contains "P2Pool sidechain syncing clears with synced stats (#3249)" "$out" \
        'p2pool-sync: synced stats clear syncing=false'
    assert_contains "P2Pool stats restored and writer restarted after sync fixture (#3249)" "$out" \
        'p2pool-sync: original stats restored and p2pool running'
}
