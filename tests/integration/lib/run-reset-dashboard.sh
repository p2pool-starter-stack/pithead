# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# Real filesystem and Compose behavior require a live reset with rollback protection.
_reset_dashboard_services_healthy() {
    [ "$(service_state dashboard)" = "running healthy" ] && [ "$(service_state p2pool)" = "running healthy" ]
}

run_reset_dashboard() {
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="reset-dashboard"
    echo ""
    it_log "── reset-dashboard phase ───────────────────────────"

    local dashboard_dir p2pool_dir
    dashboard_dir="$(env_on_box DASHBOARD_DATA_DIR)"
    p2pool_dir="$(env_on_box P2POOL_DATA_DIR)"
    if [ -z "$dashboard_dir" ] || [ -z "$p2pool_dir" ]; then
        it_fail "reset-dashboard phase preconditions" ".env is missing DASHBOARD_DATA_DIR/P2POOL_DATA_DIR"
        return
    fi
    if [[ "$dashboard_dir$p2pool_dir" == *$'\n'* || "$dashboard_dir$p2pool_dir" == *$'\r'* ]]; then
        it_fail "reset-dashboard phase preconditions" "data directories contain line breaks"
        return
    fi
    # Reuse the dashboard image so the failure fixture needs no registry pull.
    local blocker_image
    blocker_image="$(rx "docker inspect --format '{{.Config.Image}}' dashboard 2>/dev/null")"

    # Unapplied config decoys distinguish the live .env targets from config-only paths.
    local decoy_dashboard decoy_p2pool decoy_config decoy_paths
    if ! decoy_paths="$(rx "dashboard=''; p2pool=''; cleanup() { [ -z \"\$dashboard\" ] || rm -rf -- \"\$dashboard\"; [ -z \"\$p2pool\" ] || rm -rf -- \"\$p2pool\"; }; trap cleanup EXIT; dashboard=\$(mktemp -d $(quote_arg "${dashboard_dir}.CONFIGONLY.XXXXXX")) || exit; p2pool=\$(mktemp -d $(quote_arg "${p2pool_dir}.CONFIGONLY.XXXXXX")) || exit; printf '%s\\n%s\\n' \"\$dashboard\" \"\$p2pool\" || exit; trap - EXIT")"; then
        it_fail "reset-dashboard phase preconditions" "could not create isolated config-only decoys"
        return
    fi
    RESET_DASHBOARD_DECOY_DASHBOARD="$(printf '%s\n' "$decoy_paths" | sed -n '1p')"
    RESET_DASHBOARD_DECOY_P2POOL="$(printf '%s\n' "$decoy_paths" | sed -n '2p')"
    if [ -z "$RESET_DASHBOARD_DECOY_DASHBOARD" ] || [ -z "$RESET_DASHBOARD_DECOY_P2POOL" ]; then
        reset_dashboard_cleanup
        it_fail "reset-dashboard phase preconditions" "isolated config-only decoys were incomplete"
        return
    fi
    decoy_dashboard="$RESET_DASHBOARD_DECOY_DASHBOARD"
    decoy_p2pool="$RESET_DASHBOARD_DECOY_P2POOL"
    if ! decoy_config="$(printf '%s' "$BASELINE_CONFIG" | jq --arg dashboard "$decoy_dashboard" --arg p2pool "$decoy_p2pool" \
        '.dashboard.data_dir=$dashboard | .p2pool.data_dir=$p2pool')" ||
        ! push_config "$decoy_config" ||
        ! rx "mkdir -p $(quote_arg "$dashboard_dir") $(quote_arg "$p2pool_dir") $(quote_arg "$decoy_dashboard") $(quote_arg "$decoy_p2pool") && : > $(quote_arg "$dashboard_dir/.itest-marker") && : > $(quote_arg "$p2pool_dir/.itest-marker") && : > $(quote_arg "$decoy_dashboard/.itest-marker") && : > $(quote_arg "$decoy_p2pool/.itest-marker")" >/dev/null 2>&1; then
        it_fail "reset-dashboard phase preconditions" "could not write the decoy config and live-dir markers"
        reset_dashboard_cleanup
        return
    fi

    local operator_uid
    operator_uid="$(rx 'id -u' 2>/dev/null)"
    it_step "operator uid on this box: ${operator_uid:-unknown} (#550's order bug only bites when this isn't 1000)"

    local mtip mheight mblock_before theight
    mtip="$(monero_chain_tip)"
    mheight="${mtip%% *}"
    if ! chain_tip_valid "$mtip"; then
        it_fail "monerod RPC before reset-dashboard" "get_info unreachable before the reset"
        reset_dashboard_cleanup
        return
    fi
    # get_info.height is one past get_info.top_block_hash's height.
    mblock_before="$(monero_block_identity "$((mheight - 1))")"
    if [ -z "$mblock_before" ]; then
        it_fail "monerod block identity before reset-dashboard" "get_block_header_by_height failed before the reset"
        reset_dashboard_cleanup
        return
    fi
    theight="$(jq_get "$(api_state)" '.sync.tari.current')"
    if [[ ! "$theight" =~ ^[0-9]+$ ]]; then
        it_fail "tari chain-untouched precondition" "dashboard did not report a numeric height before the reset"
        reset_dashboard_cleanup
        return
    fi

    local failures_before_reset="$IT_FAIL"
    it_step "pithead reset-dashboard -y…"
    pithead reset-dashboard -y >/dev/null 2>&1
    assert_rc "reset-dashboard succeeds" "$?" "0"

    assert_eq "reset wiped the .env dashboard dir, not the config-only one" \
        "$(rx "test -e $(quote_arg "$dashboard_dir/.itest-marker") && echo present || echo gone")" "gone"
    assert_eq "reset wiped the .env p2pool dir, not the config-only one" \
        "$(rx "test -e $(quote_arg "$p2pool_dir/.itest-marker") && echo present || echo gone")" "gone"
    assert_eq "reset never touched the unapplied config-only dashboard dir (#139)" \
        "$(rx "test -e $(quote_arg "$decoy_dashboard/.itest-marker") && echo present || echo absent")" "present"
    assert_eq "reset never touched the unapplied config-only p2pool dir (#139)" \
        "$(rx "test -e $(quote_arg "$decoy_p2pool/.itest-marker") && echo present || echo absent")" "present"

    assert_eq "recreated dashboard dir owned by APP_UID 1000 (#550)" \
        "$(rx "stat -c %u $(quote_arg "$dashboard_dir") 2>/dev/null")" "1000"
    assert_eq "recreated p2pool dir owned by APP_UID 1000 (#550)" \
        "$(rx "stat -c %u $(quote_arg "$p2pool_dir") 2>/dev/null")" "1000"
    assert_eq "recreated p2pool/stats dir owned by APP_UID 1000 (#550)" \
        "$(rx "stat -c %u $(quote_arg "$p2pool_dir/stats") 2>/dev/null")" "1000"

    # Both reset services must pass their own healthchecks, not merely remain running while starting.
    wait_for 240 5 "dashboard and p2pool healthy after reset-dashboard" _reset_dashboard_services_healthy || true
    pithead status >/dev/null 2>&1
    assert_rc "status OK after reset-dashboard" "$?" "0"
    assert_eq "dashboard container healthy after reset" "$(service_state dashboard)" "running healthy"
    assert_eq "p2pool container healthy after reset" "$(service_state p2pool)" "running healthy"
    # Fresh mining telemetry must follow the reset of p2pool's session counter.
    [ "$SKIP_MINING_ASSERTS" = "1" ] || wait_miner_running 180 || true
    [ "$SKIP_MINING_ASSERTS" = "1" ] || wait_hashes_flowing 300 || true
    local reset_state
    reset_state="$(api_state)"
    assert_mining_state "$SKIP_MINING_ASSERTS" "$(jq_get "$reset_state" '.proxy_workers')" \
        "$(jq_get "$reset_state" '.stratum.total_hashes')" "$EXPECTED_WORKERS"
    [ "$SKIP_MINING_ASSERTS" = "1" ] || assert_share_stats_live

    # Dashboard health can precede its first successful Monero RPC connection.
    wait_for 120 5 "monerod RPC after reset-dashboard" monero_chain_tip || true
    local mtip2 mheight2
    mtip2="$(monero_chain_tip)"
    mheight2="${mtip2%% *}"
    if [ -n "$mblock_before" ] && chain_tip_valid "$mtip2"; then
        assert_num_ge "monerod height never rewound across reset-dashboard (#139)" "$mheight2" "$mheight"
        assert_eq "the pre-reset monero block is still the same block (chain untouched, #139)" \
            "$(monero_block_identity "$((mheight - 1))")" "$mblock_before"
    else
        it_fail "monero chain-untouched check" "get_info unreachable before or after the reset"
    fi
    local theight2
    theight2="$(jq_get "$(api_state)" '.sync.tari.current')"
    if [[ "$theight2" =~ ^[0-9]+$ ]]; then
        assert_num_ge "tari height never rewound across reset-dashboard" "$theight2" "$theight"
    else
        it_fail "tari chain-untouched check" "dashboard did not report a numeric height before and after the reset"
    fi

    # A failed reset must reach restoration before another destructive fault.
    if [ "$IT_FAIL" -gt "$failures_before_reset" ]; then
        reset_dashboard_cleanup
        return
    fi

    # A foreign p2pool container forces a real Compose name conflict.
    if [ -n "$blocker_image" ]; then
        it_step "forcing a real compose failure to exercise the #557 friendly-failure branch…"
        # Hold the mutation lock until the captured blocker is removed.
        local fail_result fail_out fail_rc
        fail_result="$(rx "source ./pithead; mutation_lock_acquire reset-dashboard-test; blocker=''; complete=0; cleanup() { [ -z \"\$blocker\" ] || docker rm -f \"\$blocker\" >/dev/null 2>&1 || true; [ \"\$complete\" = 1 ] || PITHEAD_LOCK_HELD=1 ./pithead up >/dev/null 2>&1 || true; mutation_lock_release; }; trap cleanup EXIT; docker rm -f p2pool >/dev/null 2>&1; blocker=\$(docker create --name p2pool $(quote_arg "$blocker_image")) || exit 0; if PITHEAD_LOCK_HELD=1 ./pithead reset-dashboard -y 2>&1; then rc=0; else rc=\$?; fi; complete=1; printf '\n__reset_dashboard_rc=%s\n' \"\$rc\"")"
        fail_rc="$(printf '%s\n' "$fail_result" | sed -n 's/^__reset_dashboard_rc=//p' | tail -n1)"
        fail_out="$(printf '%s\n' "$fail_result" | sed '/^__reset_dashboard_rc=/d')"
        if [[ ! "$fail_rc" =~ ^[0-9]+$ ]]; then
            it_fail "reset-dashboard compose-failure fixture" "could not create the isolated p2pool name blocker"
            pithead up >/dev/null 2>&1 || true
            wait_status_ok 240 || true
            reset_dashboard_cleanup
            return
        fi
        assert_rc "reset-dashboard exits 1 on a real compose failure (#557 fail-closed unchanged)" "$fail_rc" "1"
        assert_contains "reset-dashboard: friendly compose-failure branch reached, not a bare errexit abort (#557)" \
            "$fail_out" "did NOT come back up"
        assert_contains "reset-dashboard: names the retry command (#557)" "$fail_out" "re-run"

        it_step "recovering: pithead reset-dashboard -y once more…"
        pithead reset-dashboard -y >/dev/null 2>&1
        wait_status_ok 240 || true
        pithead status >/dev/null 2>&1
        assert_rc "status OK after recovering from the forced compose failure" "$?" "0"
    else
        it_fail "#557 forced compose-failure check" "could not read the dashboard container's image to build a name-clash blocker"
    fi
    reset_dashboard_cleanup
}
