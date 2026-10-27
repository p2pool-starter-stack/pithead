#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/tests/integration/lib/reset-restore-miner.sh"
td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT
OUT_DIR=$td
RR_MINER_ENABLED=0 RR_MINER_NAMES='[]' RR_MINER_LOCAL='' RR_MINER_BASELINE='[]'
fixture_mode=enabled unit_rc=0 fixture_rows='[["local",0,1,0],["rig",0,1,0]]'
passes=0 failures=0 skips=0 polls=0
it_pass() { passes=$((passes + 1)); }
it_fail() { failures=$((failures + 1)); }
it_skip_leg() { skips=$((skips + 1)); }
rx() {
    case "$1" in
    'source ./pithead'*) printf '%s' "$fixture_mode" ;;
    jq*) printf local ;;
    *'is-active --quiet'*) return "$unit_rc" ;;
    *systemctl*)
        printf 'LoadState=loaded\nActiveState=active\nSubState=running\nResult=success\nExecMainStatus=0\n'
        return "$unit_rc"
        ;;
    *) return 99 ;;
    esac
}
rr_miner_workers() { printf '%s' "$fixture_rows"; }
wait_for() {
    shift 3
    if [ "$1:${2:-}" = rr_miner_returned:true ] && [ "${advance:-0}" = 1 ]; then
        fixture_rows=$(jq -c 'map(.[3] += 1)' <<<"$fixture_rows")
    fi
    local n
    for n in 1 2 3; do
        polls=$((polls + 1))
        "$@" && return 0
    done
    return 1
}
rr_miner_prepare
[ "$RR_MINER_NAMES" = '["local","rig"]' ] && [ "$RR_MINER_ENABLED" = 1 ]
rr_miner_state before-up
fixture_rows='[["local",0,1,1],["rig",0,1,1]]'
advance=1
rr_miner_recovered
advance=0
[ "$passes:$failures" = 1:0 ]
grep -qx before-reset "$td/reset-restore.miner-state.log"
grep -qx before-up "$td/reset-restore.miner-state.log"
grep -qx recovered "$td/reset-restore.miner-state.log"
for fixture_rows in '[]' '[["rig",0,1,4]]' '[["local",0,1,4]]' '[["local",0,0,4],["rig",0,1,4]]'; do
    if rr_miner_recovered; then
        printf 'FAIL: missing saved worker passed\n' >&2
        exit 1
    fi
done
fixture_rows='[["local",0,1,4],["rig",0,1,4]]'
if rr_miner_recovered; then
    printf 'FAIL: unchanged accepted counters passed as new shares\n' >&2
    exit 1
fi
RR_MINER_BASELINE='[["local",0,1,1],["rig",0,1,1]]'
fixture_rows='[["local",0,1,2],["rig",0,1,1]]'
if rr_miner_returned true; then
    printf 'FAIL: another worker masked missing share progress\n' >&2
    exit 1
fi
[ "$failures" = 5 ] && [ "$polls" -ge 18 ]
[ "$RR_MINER_NAMES" = '["local","rig"]' ]
for fixture_rows in '[]' '[["rig",0,1,4]]'; do
    if rr_miner_prepare; then
        printf 'FAIL: absent local miner passed precondition\n' >&2
        exit 1
    fi
done
unit_rc=1
if rr_miner_state failure-control; then
    printf 'FAIL: unreadable unit state passed\n' >&2
    exit 1
fi
unit_rc=0
fixture_mode=unknown
if rr_miner_prepare; then
    printf 'FAIL: unknown platform state passed\n' >&2
    exit 1
fi
fixture_mode=disabled RR_MINER_ENABLED=0
rr_miner_prepare
rr_miner_recovered
[ "$skips" = 1 ]
SKIP_MINING_ASSERTS=1 rr_miner_prepare
[ "$skips" = 2 ]
printf 'reset restore miner selftest: PASS (identity, binding, shares, bounds, state and opt-outs)\n'
