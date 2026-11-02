#!/usr/bin/env bash
set -euo pipefail
echo "== integration eventual waits =="
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$HERE/lib.sh"
source "$HERE/lib/selftest/fake-eventual.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ready='{"proxy_workers":1,"stratum":{"total_hashes":1},"sync":{"monero":{"state":"done"},"tari":{"state":"done"}},"pool":{"type":"Mini"},"db_healthy":true,"share_stats":[{}]}'

drive() (
    local waiter=$1 mode=$2 clock=0 bound=40
    local pending expression
    case "$waiter" in
    wait_miner_running | wait_stratum_hashes) expression='.proxy_workers=0' ;;
    wait_tari_synced) expression='.sync.tari.state="loading"' ;;
    wait_pool_ready) expression='.pool.type="Unknown"' ;;
    wait_hashes_flowing) expression='.stratum.total_hashes=0' ;;
    _pred_monero_panel_done) expression='.sync.monero.state="loading"' ;;
    _pred_share_stats_nonempty) expression='.share_stats=[]' ;;
    _pred_db_healthy_is) expression='.db_healthy=false' ;;
    *) expression='.' ;;
    esac
    [ "${3:-}" != hashes ] || expression='.stratum.total_hashes=0'
    pending=$(jq -c "$expression" <<<"$ready")
    now_s() { printf '%s\n' "$clock"; }
    sleep() { clock=$((clock + $1)); }
    api_state() { fake_eventual "$work/reads" "$mode" 2 "$pending" "$ready"; }
    monero_caught_up() { [ "$(fake_eventual "$work/reads" "$mode" 2 syncing 'done')" = 'done' ]; }
    pithead() { [ "$(fake_eventual "$work/reads" "$mode" 2 unhealthy healthy)" = healthy ]; }
    status_churn_snapshot() { printf 'container started 0\n'; }
    printf '0\n' >"$work/reads"
    local rc=0
    case "$waiter" in
    wait_pool_ready) "$waiter" "$bound" Mini >"$work/output" 2>&1 || rc=$? ;;
    _pred_db_healthy_is) wait_for "$bound" 5 "$waiter" "$waiter" true >"$work/output" 2>&1 || rc=$? ;;
    _pred_*) wait_for "$bound" 5 "$waiter" "$waiter" >"$work/output" 2>&1 || rc=$? ;;
    *) "$waiter" "$bound" >"$work/output" 2>&1 || rc=$? ;;
    esac
    local reads
    reads=$(cat "$work/reads")
    case "$mode/$waiter" in
    never/* | flapping/wait_status_ok)
        [ "$rc" = 1 ] && [ "$clock" = "$bound" ] && [ "$reads" -ge 5 ] || return 1
        grep -Fq "timed out after ${bound}s" "$work/output" || return 1
        ;;
    after/wait_status_ok)
        [ "$rc" = 0 ] && [ "$clock" = 15 ] && [ "$reads" = 4 ] || return 1
        ;;
    after/*)
        [ "$rc" = 0 ] && [ "$clock" -ge 10 ] && [ "$clock" -le 20 ] && [ "$reads" = 3 ] || return 1
        ;;
    flapping/*)
        [ "$rc" = 0 ] && [ "$reads" = 2 ] || return 1
        ;;
    esac
    if [ "$waiter" = wait_tari_synced ]; then
        [ "$TARI_WAIT_TIMED_OUT" = "$rc" ] || return 1
    fi
    return 0
)

for waiter in wait_status_ok wait_stratum_hashes wait_monero_synced wait_miner_running \
    wait_tari_synced wait_pool_ready wait_hashes_flowing _pred_monero_panel_done _pred_share_stats_nonempty _pred_db_healthy_is; do
    for mode in after never flapping; do
        if drive "$waiter" "$mode"; then
            printf 'PASS: %s %s\n' "$waiter" "$mode"
        else
            printf 'FAIL: %s %s\n' "$waiter" "$mode" >&2
            cat "$work/output" >&2
            exit 1
        fi
    done
done
for mode in after never flapping; do
    if ! drive wait_stratum_hashes "$mode" hashes; then
        printf 'FAIL: wait_stratum_hashes %s hashes\n' "$mode" >&2
        exit 1
    fi
done

eval "$(sed -n '/^wait_db() {/,/^}/p' "$HERE/lib/disk-enospc-target.sh")"
db_drive() (
    mode=$1 clock=0 rc=0
    printf '0\n' >"$work/reads"
    sleep() {
        clock=$((clock + $1))
        [ "$clock" -le 1000 ] || exit 99
    }
    curl() { fake_eventual "$work/reads" "$mode" 2 '{"db_healthy":false}' '{"db_healthy":true}'; }
    wait_db true || rc=$?
    if [ "$mode" = never ]; then
        [ "$rc" = 1 ] && [ "$clock" = 90 ]
    else
        [ "$rc" = 0 ] && [ "$clock" = 10 ]
    fi
)
for mode in after never; do
    db_drive "$mode" || {
        printf 'FAIL: wait_db %s\n' "$mode" >&2
        exit 1
    }
    printf 'PASS: wait_db %s\n' "$mode"
done

printf '0\n' >"$work/reads"
[ "$(fake_eventual "$work/reads" after 1 'not ready' 'ready with spaces')" = 'not ready' ]
[ "$(fake_eventual "$work/reads" after 1 'not ready' 'ready with spaces')" = 'ready with spaces' ]
[ "$(cat "$work/reads")" = 2 ]
[ "$(fake_eventual "$work/other" never 0 pending ready)" = pending ]
[ "$(cat "$work/other")" = 1 ]
for invalid in -1 01 broken; do
    if fake_eventual "$work/reads" after "$invalid" pending ready; then exit 1; fi
done
if fake_eventual "$work/reads" invalid 1 pending ready; then exit 1; fi
printf 'invalid\n' >"$work/reads"
if fake_eventual "$work/reads" after 1 pending ready; then exit 1; fi
printf 'PASS: file-backed fake survives substitutions and validates its state\n'
