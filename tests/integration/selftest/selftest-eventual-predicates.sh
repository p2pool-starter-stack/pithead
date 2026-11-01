#!/usr/bin/env bash
set -euo pipefail
echo "== integration eventual predicates =="
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$HERE/lib.sh"
source "$HERE/lib/selftest/fake-eventual.sh"
source "$HERE/lib/rigforge-writable-keys.sh"
source "$HERE/lib/tari-readiness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
extract() {
    eval "$(sed -n "/^${1}() {/,/^}/p" "$HERE/lib/$2")"
    declare -F "$1" >/dev/null
}
extract _pred_hashes_advanced live-xvb-support.sh
extract _pred_xvb_feed_fresh live-state-support.sh
extract _pred_xvb_routed_visible live-state-support.sh
extract _pred_upgrade_workers_capture live-state-support.sh
extract worker_names live-upgrade-support.sh
extract _pred_worker_set live-upgrade-support.sh
extract rr_caddy_stable reset-restore-web.sh

drive() (
    waiter=$1 mode=$2 clock=0 rc=0
    printf '0\n' >"$work/reads"
    printf 'pending\n' >"$work/last"
    now_s() { printf '%s\n' "$clock"; }
    sleep() {
        clock=$((clock + $1))
        [ "$clock" -le 1000 ] || exit 99
    }
    it_step() { :; }
    it_pass() { :; }
    it_fail() { printf 'FAILED %s: %s\n' "$1" "$2"; }
    assert_tari_synced_required() { printf 'ASSERTED %s\n' "$1"; }
    obs() { fake_eventual "$work/reads" "$mode" 2 pending ready | tee "$work/last"; }
    is_ready() { [ "$(cat "$work/last")" = ready ]; }
    export XVB_FEED_TS_BEFORE=100 UPGRADE_BEFORE_WORKERS=w1 EXPECTED_WORKERS=1
    case "$waiter" in
    _pred_hashes_advanced)
        api_state() { obs >/dev/null && if is_ready; then echo '{"stratum":{"total_hashes":10}}'; else echo '{"stratum":{"total_hashes":3}}'; fi; }
        wait_for 40 5 d _pred_hashes_advanced 5 >"$work/output" 2>&1 || rc=$?
        ;;
    _pred_xvb_feed_fresh)
        api_state() { obs >/dev/null && if is_ready; then echo '{"hashrate":{"xvb_stale":false}}'; else echo '{"hashrate":{"xvb_stale":true}}'; fi; }
        rx() { if is_ready; then echo '{"ts":200}'; else echo '{"ts":50}'; fi; }
        wait_for 40 5 d _pred_xvb_feed_fresh >"$work/output" 2>&1 || rc=$?
        ;;
    _pred_xvb_routed_visible)
        api_state() { obs >/dev/null && if is_ready; then echo '{"hashrate":{"mode_name":"XVB","xvb_routed_1h":"5 H/s"},"shares_window":{"count":1}}'; else echo '{"hashrate":{"mode_name":"XVB","xvb_routed_1h":"0.00 H/s"},"shares_window":{"count":0}}'; fi; }
        wait_for 40 5 d _pred_xvb_routed_visible >"$work/output" 2>&1 || rc=$?
        ;;
    _pred_upgrade_workers_capture)
        api_state() { obs >/dev/null && if is_ready; then echo '{"workers":[{"name":"w1"}],"proxy_workers":1}'; else echo '{"workers":[],"proxy_workers":0}'; fi; }
        wait_for 40 5 d _pred_upgrade_workers_capture >"$work/output" 2>&1 || rc=$?
        ;;
    _pred_worker_set)
        api_state() { obs >/dev/null && if is_ready; then echo '{"workers":[{"name":"w1"}]}'; else echo '{"workers":[]}'; fi; }
        wait_for 40 5 d _pred_worker_set w1 >"$work/output" 2>&1 || rc=$?
        ;;
    _pred_rig_pool_urls)
        _worker_detail() { obs >/dev/null && if is_ready; then echo '{"rig_config":{"pools":[{"url":"u"}]}}'; else echo '{"rig_config":{}}'; fi; }
        wait_for 40 5 d _pred_rig_pool_urls rig '["u"]' >"$work/output" 2>&1 || rc=$?
        ;;
    assert_fresh_tari_synced_required)
        api_state() { obs >/dev/null && if is_ready; then echo '{"sync":{"tari":{"state":"done"}}}'; else echo '{"sync":{"tari":{"state":"loading"}}}'; fi; }
        assert_fresh_tari_synced_required >"$work/output" 2>&1 || rc=$?
        ;;
    rr_caddy_stable)
        rr_caddy_snapshot() { obs >/dev/null && is_ready && echo 'id 0 t true healthy'; }
        rr_caddy_stable >"$work/output" 2>&1 || rc=$?
        ;;
    rr_caddy_restarted)
        rr_caddy_snapshot() { obs >/dev/null && is_ready && echo "id $(cat "$work/reads") t true healthy"; }
        rr_caddy_stable >"$work/output" 2>&1 || rc=$?
        ;;
    esac
    case "$waiter/$mode" in
    rr_caddy_restarted/after) [ "$rc" = 1 ] ;;
    rr_caddy_stable/after) [ "$rc" = 0 ] && [ "$clock" = 70 ] ;;
    rr_caddy_stable/never) [ "$rc" = 1 ] && [ "$clock" = 60 ] ;;
    assert_fresh_tari_synced_required/never)
        grep -Fq 'expected fresh [done] within 300s, last fresh state [loading]' "$work/output" && [ "$clock" = 300 ]
        ;;
    assert_fresh_tari_synced_required/after) grep -Fxq 'ASSERTED done' "$work/output" ;;
    */never) [ "$rc" = 1 ] && grep -Fq 'timed out after 40s' "$work/output" && [ "$clock" = 40 ] ;;
    *) [ "$rc" = 0 ] && [ "$clock" -gt 0 ] && [ "$clock" -lt 40 ] ;;
    esac
)

for waiter in _pred_hashes_advanced _pred_xvb_feed_fresh _pred_xvb_routed_visible _pred_upgrade_workers_capture \
    _pred_worker_set _pred_rig_pool_urls assert_fresh_tari_synced_required rr_caddy_stable; do
    for mode in after never; do
        if drive "$waiter" "$mode"; then
            printf 'PASS: %s %s\n' "$waiter" "$mode"
        else
            printf 'FAIL: %s %s\n' "$waiter" "$mode" >&2
            cat "$work/output" >&2
            exit 1
        fi
    done
done
if drive rr_caddy_restarted after; then
    printf 'PASS: rr_caddy_stable refuses a restart inside the window\n'
else
    printf 'FAIL: rr_caddy_stable restart\n' >&2
    exit 1
fi
