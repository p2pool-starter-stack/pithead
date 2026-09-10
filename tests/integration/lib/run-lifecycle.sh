# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
run_lifecycle() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="lifecycle"
    echo ""
    it_log "── lifecycle + failover phase ──────────────────────"

    # restart brings the stack back healthy.
    it_step "pithead restart…"
    pithead restart >/dev/null 2>&1
    wait_status_ok 240 || true
    pithead status >/dev/null 2>&1
    assert_rc "status OK after restart" "$?" "0"

    # apply that changes the sidechain recreates only the affected containers, preserving
    # secrets. We flip main<->mini and assert the token/onions are untouched, then revert.
    local cur_pool fp_before
    cur_pool="$(jq_get "$BASELINE_CONFIG" '.p2pool.pool')"
    cur_pool="${cur_pool:-main}"
    local other
    [ "$cur_pool" = "mini" ] && other="main" || other="mini"
    fp_before="$(secret_fingerprint)"
    # ensure_owner whole-tree migration (#255): plant a root-owned file UNDER a data dir (the
    # root-container-era signature — user-owned dir, root-owned contents) and prove this apply chowns
    # it to the container uid, the exact regression MEMORY flags ("scan contents, not just the dir").
    # Piggybacks the pool-flip apply below, which always runs ensure_directories -> ensure_owner.
    # Local mode only (has data dirs); a stub can't create a foreign-uid inode, so this is tier-4.
    local own_dir own_probe=""
    if has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        own_dir="$(env_on_box DASHBOARD_DATA_DIR)"
        if [ -n "$own_dir" ]; then
            own_probe="$own_dir/.itest-owner-probe"
            it_step "planting a root-owned file under $own_dir to exercise ensure_owner (#255)…"
            rx "sudo touch $(quote_arg "$own_probe") && sudo chown 0:0 $(quote_arg "$own_probe")" >/dev/null 2>&1
        fi
    fi
    push_config "$(render_scenario_config "$BASELINE_CONFIG" "p2pool.pool=$other")"
    it_step "apply pool $cur_pool -> ${other}…"
    pithead apply -y >/dev/null 2>&1
    wait_status_ok 180 || true
    assert_eq "secrets preserved across pool change" "$(secret_fingerprint)" "$fp_before"
    # APP_UID is 1000 in pithead; the migrated contents must now be owned by it, not root.
    if [ -n "$own_probe" ]; then
        assert_eq "apply migrates root-owned CONTENTS to the container uid (#255)" \
            "$(rx "stat -c %u $(quote_arg "$own_probe") 2>/dev/null")" "1000"
        rx "sudo rm -f $(quote_arg "$own_probe")" >/dev/null 2>&1 || true
    fi
    # .pool.type lags a sidechain switch until peers on the new chain connect — wait + three-way
    # verdict, don't assert cold on a peer-timing state (#54, #687).
    assert_pool_switched "pool actually changed" "$(pool_label "$other")"

    # Node-down failover (#31): stop monerod -> status non-zero (node down), dashboard rejects
    # workers (xmrig-proxy stopped) -> start monerod -> readmitted -> status 0 again.
    if has_compose_profile "$(env_on_box COMPOSE_PROFILES)" local_node; then
        it_step "stopping monerod to exercise node-down failover…"
        rx "docker compose stop monerod" >/dev/null 2>&1
        wait_for 120 5 "status to report node down" _pred_status_down || true
        pithead status >/dev/null 2>&1
        assert_rc "status non-zero when node down" "$?" "1"
        it_step "starting monerod and waiting for readmit…"
        rx "docker compose start monerod" >/dev/null 2>&1
        wait_status_ok 240 || true
        pithead status >/dev/null 2>&1
        assert_rc "status OK after node recovery" "$?" "0"
    else
        it_skip_leg "node-down failover" "remote mode: no local monerod to stop" "by-design"
    fi

    # backup → restore round-trip (#102): a backup archives config/.env/onions/dashboard; a
    # restore brings them back. We change the pool, restore, and assert the pool reverted and
    # secrets survived — exercising both CLI verbs end-to-end (not just the rollback net).
    it_step "backup → restore round-trip…"
    if pithead backup -y --no-encrypt >/dev/null 2>&1; then
        local arch
        arch="$(rx 'ls -t backups/pithead-backup-*.tar.gz 2>/dev/null | head -n1')"
        if [ -n "$arch" ]; then
            local fp_b
            fp_b="$(secret_fingerprint)"
            local backed_pool
            backed_pool="$(jq_get "$(api_state)" '.pool.type')"
            # Diverge from the backed-up state, then restore it back.
            push_config "$(render_scenario_config "$BASELINE_CONFIG" "p2pool.pool=$other")"
            pithead apply -y >/dev/null 2>&1
            pithead down >/dev/null 2>&1
            pithead restore -y "$arch" >/dev/null 2>&1
            pithead up >/dev/null 2>&1
            wait_status_ok 240 || true
            # pool.type lags peer reconnect after restore+up — wait + three-way verdict, don't assert
            # cold on a peer-timing state (#54, #687).
            assert_pool_switched "restore reverts the pool to the backed-up value" "$backed_pool"
            assert_eq "restore preserves secrets" "$(secret_fingerprint)" "$fp_b"
            rx "rm -f $(quote_arg "$arch")" >/dev/null 2>&1 || true
        else
            it_fail "backup produced an archive" "no backups/pithead-backup-*.tar.gz"
        fi
    else
        it_fail "pithead backup succeeded" "backup returned non-zero"
    fi
}

_pred_status_down() { ! pithead status >/dev/null 2>&1; }
# --- Fault-injection phase (--fault-injection) ------------------------------
# Break local monerod three ways, assert status/failover, then restore; opt-in because debounces are slow.
_monerod_is() { # _monerod_is <state> [<health>]
    local s
    s="$(service_state monerod)"
    [ "$(svc_state_of "$s")" = "$1" ] && { [ -z "${2:-}" ] || [ "$(svc_health_of "$s")" = "$2" ]; }
}
_pred_monerod_missing() { _monerod_is missing; }
_pred_monerod_unhealthy() { _monerod_is running unhealthy; }
_pred_monerod_healthy() { _monerod_is running healthy; }
_pred_proxy_stopped() { [ "$(svc_state_of "$(service_state xmrig-proxy)")" != "running" ]; }
_pred_failover_armed() {
    local st
    st="$(api_state)"
    [ "$(jq_get "$st" '.monero_sync.reachable')" = "true" ] && [ "$(jq_get "$st" '.miner_released')" = "true" ] && [ "$(jq_get "$st" '.workers_rejected')" = "false" ] && [ "$(svc_state_of "$(service_state xmrig-proxy)")" = "running" ]
}
_pred_tor_stopped() { [ "$(svc_state_of "$(service_state tor)")" != "running" ]; }
_pred_tor_healthy() {
    local s
    s="$(service_state tor)"
    [ "$(svc_state_of "$s")" = "running" ] && { [ "$(svc_health_of "$s")" = "healthy" ] || [ "$(svc_health_of "$s")" = "none" ]; }
}
