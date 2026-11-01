#!/usr/bin/env bash
set -euo pipefail
echo "== integration lifecycle eventual waits =="
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$HERE/lib.sh"
source "$HERE/lib/selftest/fake-eventual.sh"
source "$HERE/lib/rigforge-apply-settle.sh"
source "$HERE/lib/rigforge-writable-keys.sh"
source "$HERE/lib/borrow-rearm.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
extract() {
    eval "$(sed -n "/^${1}() {/,/^}/p" "$HERE/lib/$2")"
    declare -F "$1" >/dev/null
}
extract wait_onion_retired run-rotate-onion.sh
extract _wait_control_status run-hardening.sh
extract recovery_wait_synced wallet-fixture-recovery.sh
extract recovery_wait_healthy wallet-fixture-recovery.sh
extract _poll_upgrade_result rigforge-upgrade.sh
extract _await_egress_state run-egress-status.sh
extract reset_restore_wait_empty run-reset-restore.sh
extract _rig_control_await run-rig-reverse.sh

out() { cat "$work/output"; }
pending_json() { jq -nc --arg s "$1" '{change_id:"c1",status:$s}'; }

drive() (
    waiter=$1 mode=$2 clock=0 rc=0
    printf '0\n' >"$work/reads"
    SECONDS=0
    date() { [ "$*" = +%s ] && printf '%s\n' "$clock"; }
    now_s() { printf '%s\n' "$clock"; }
    sleep() {
        clock=$((clock + $1))
        SECONDS=$((SECONDS + $1))
        [ "$clock" -le 1000 ] || exit 99
    }
    it_step() { :; }
    it_pass() { :; }
    it_fail() { printf 'FAILED %s: %s\n' "$1" "$2"; }
    fx() { fake_eventual "$work/reads" "$mode" 2 "$1" "$2"; }
    case "$waiter" in
    wait_onion_retired)
        export ROTATE_ONION_OLD_ENV_FP=fp
        rotate_onion_env_fingerprint() { printf 'fp\n'; }
        _onion_reachable_external() { [ "$(fx reachable retired)" = reachable ]; }
        wait_onion_retired onion env >"$work/output" 2>&1 || rc=$?
        ;;
    _settle_worker_apply)
        pred() { [ "$(fx no yes)" = yes ]; }
        _settle_worker_apply k desc "$(pending_json accepted)" pred >"$work/output" 2>"$work/err" || rc=$?
        ;;
    _settle_worker_apply_key)
        _pred_rig_config_key() { [ "$(fx no yes)" = yes ]; }
        _settle_worker_apply_key rig k '1' "$(pending_json accepted)" >"$work/output" 2>"$work/err" || rc=$?
        ;;
    _settle_worker_apply_maxt)
        _pred_feed_maxt() { [ "$(fx no yes)" = yes ]; }
        _settle_worker_apply_maxt rig 101 "$(pending_json accepted)" >"$work/output" 2>"$work/err" || rc=$?
        ;;
    _settle_history_row)
        _worker_detail() { jq -nc --arg s "$(fx accepted applied)" '{history:[{change_id:"c1",status:$s}]}'; }
        _settle_history_row rig c1 >"$work/output" 2>"$work/err" || rc=$?
        ;;
    wait_borrow_rearm)
        export IT_BORROW_REARM_REQUEST="$work/request" IT_BORROW_REARM_ACK="$work/ack" IT_BORROW_REARM_TOKEN=t
        _borrow_rearm_ack_matches() { [ "$(fx no yes)" = yes ]; }
        wait_borrow_rearm >"$work/output" 2>&1 || rc=$?
        ;;
    _wait_control_status)
        rx() { fx previewed applied; }
        _wait_control_status dir id previewed 90 >"$work/output" 2>&1 || rc=$?
        ;;
    recovery_wait_synced)
        api_state() { jq -nc --arg s "$(fx loading "done")" '{sync:{monero:{state:$s},tari:{state:$s}}}'; }
        warn() { printf '%s\n' "$*"; }
        recovery_wait_synced 60 >"$work/output" 2>&1 || rc=$?
        ;;
    recovery_wait_healthy)
        export RESTORE_DIR=dir
        on_bench() { [ "$(fx no yes)" = yes ]; }
        recovery_wait_healthy 60 >"$work/output" 2>&1 || rc=$?
        ;;
    _poll_upgrade_result)
        rx() { pending_json "$(fx running applied)"; }
        _poll_upgrade_result id 60 >"$work/output" 2>&1 || rc=$?
        ;;
    _await_egress_state)
        rx() { [ "$(fx 0 1000)" -gt 0 ] && printf '%s\n' "$((clock + 1))"; }
        api_state() { jq -nc --arg s "$(fx enforced missing)" '{egress:{summary:{firewall_state:$s}}}'; }
        _await_egress_state missing 0 >"$work/output" 2>&1 || rc=$?
        ;;
    reset_restore_wait_empty)
        rx() {
            [ "$(fx no yes)" = yes ] && return 0
            printf 'residue-id\n'
        }
        reset_restore_wait_empty 60 >"$work/output" 2>&1 || rc=$?
        ;;
    _rig_control_await)
        export RIG_HOST=rig RIG_CONTROL_PORT=1
        rx() { pending_json "$(fx running applied)"; }
        _rig_control_await c1 applied 30 >"$work/output" 2>&1 || rc=$?
        ;;
    esac
    reads=$(cat "$work/reads")
    if [ "$mode" = never ]; then
        case "$waiter" in
        wait_onion_retired) [ "$rc" = 4 ] && [ "$clock" = 105 ] || return 1 ;;
        _settle_worker_apply | _settle_worker_apply_key | _settle_worker_apply_maxt)
            [[ "$(cat "$work/output")" == accepted\|*\|c1 ]] || return 1
            grep -Fq 'timed out after 90s' "$work/err" || return 1
            ;;
        _settle_history_row) [ "$(cat "$work/output")" = accepted ] && grep -Fq 'timed out after 90s' "$work/err" || return 1 ;;
        wait_borrow_rearm) [ "$rc" = 1 ] && grep -Fq 'did not acknowledge this request' "$work/output" || return 1 ;;
        _wait_control_status) [ "$rc" = 1 ] && [ "$clock" = 90 ] || return 1 ;;
        recovery_wait_synced) [ "$rc" = 1 ] && grep -Fq "sync panels still 'loading/loading' after 60s" "$work/output" || return 1 ;;
        recovery_wait_healthy) [ "$rc" = 1 ] && [ "$clock" -ge 60 ] || return 1 ;;
        _poll_upgrade_result) [ "$rc" = 0 ] && [ ! -s "$work/output" ] && [ "$clock" -ge 60 ] || return 1 ;;
        _await_egress_state) [ "$(cat "$work/output")" = enforced ] && [ "$clock" -ge 210 ] || return 1 ;;
        reset_restore_wait_empty) [ "$rc" = 1 ] && grep -Fxq residue-id "$work/output" && [ "$clock" -ge 60 ] || return 1 ;;
        _rig_control_await) [ "$rc" = 1 ] && [ "$clock" -ge 30 ] || return 1 ;;
        esac
    else
        [ "$rc" = 0 ] && [ "$clock" -gt 0 ] || return 1
        case "$waiter" in
        _settle_worker_apply) [ "$(cat "$work/output")" = 'applied|k|c1' ] || return 1 ;;
        _settle_worker_apply_key) [ "$(cat "$work/output")" = 'applied|k|c1' ] || return 1 ;;
        _settle_worker_apply_maxt) [ "$(cat "$work/output")" = 'applied|max_temp_c|c1' ] || return 1 ;;
        _settle_history_row) [ "$(cat "$work/output")" = applied ] || return 1 ;;
        _wait_control_status) [ "$(cat "$work/output")" = applied ] || return 1 ;;
        _poll_upgrade_result) [ "$(cat "$work/output")" = applied ] || return 1 ;;
        _await_egress_state) [ "$(cat "$work/output")" = missing ] || return 1 ;;
        esac
        [ "$reads" -ge 3 ] || return 1
    fi
)

for waiter in wait_onion_retired _settle_worker_apply _settle_worker_apply_key _settle_worker_apply_maxt \
    _settle_history_row wait_borrow_rearm _wait_control_status recovery_wait_synced recovery_wait_healthy \
    _poll_upgrade_result _await_egress_state reset_restore_wait_empty _rig_control_await; do
    for mode in after never; do
        if drive "$waiter" "$mode"; then
            printf 'PASS: %s %s\n' "$waiter" "$mode"
        else
            printf 'FAIL: %s %s\n' "$waiter" "$mode" >&2
            out >&2
            exit 1
        fi
    done
done
