# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# --- reset-dashboard phase (--reset-dashboard) -------------------------------
# `pithead reset-dashboard` (#2346) was tier-1-only: its bug history (#139 wrong wipe target,
# #550 chown/mkdir order, #557 swallowed compose failure) lives entirely in real .env resolution,
# real ownership and a real compose failure — none of which a stubbed docker/sudo can see. This
# proves the verb against the live box, then restores it. DESTRUCTIVE-then-restored.
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
    # An already-pulled image, captured before the first reset removes the dashboard container, so
    # the later #557 blocker never needs a registry pull.
    local blocker_image
    blocker_image="$(rx "docker inspect --format '{{.Config.Image}}' dashboard 2>/dev/null")"

    # #139: point config.json at decoy dirs WITHOUT applying, so .env (the live deployment) still
    # names the real dirs. reset-dashboard must wipe those, never the unapplied config-only paths.
    local decoy_dashboard="${dashboard_dir}.CONFIGONLY" decoy_p2pool="${p2pool_dir}.CONFIGONLY"
    push_config "$(render_scenario_config "$BASELINE_CONFIG" "dashboard.data_dir=$decoy_dashboard" "p2pool.data_dir=$decoy_p2pool")"
    rx "mkdir -p $(quote_arg "$dashboard_dir") $(quote_arg "$p2pool_dir") && : > $(quote_arg "$dashboard_dir/.itest-marker") && : > $(quote_arg "$p2pool_dir/.itest-marker")" >/dev/null 2>&1

    local operator_uid
    operator_uid="$(rx 'id -u' 2>/dev/null)"
    it_step "operator uid on this box: ${operator_uid:-unknown} (#550's order bug only bites when this isn't 1000)"

    # Chain fingerprint (#139's whole point: wipe dashboard/p2pool, never the chains).
    local mtip mheight mblock_before theight
    mtip="$(monero_chain_tip)"
    mheight="${mtip%% *}"
    chain_tip_valid "$mtip" && mblock_before="$(monero_block_identity "$mheight")"
    theight="$(jq_get "$(api_state)" '.sync.tari.current')"

    it_step "pithead reset-dashboard -y…"
    pithead reset-dashboard -y >/dev/null 2>&1
    assert_rc "reset-dashboard succeeds" "$?" "0"

    # #139: the LIVE .env dirs were wiped (marker gone); the unapplied config-only decoys, never
    # created by apply, were never touched either.
    assert_eq "reset wiped the .env dashboard dir, not the config-only one" \
        "$(rx "test -e $(quote_arg "$dashboard_dir/.itest-marker") && echo present || echo gone")" "gone"
    assert_eq "reset wiped the .env p2pool dir, not the config-only one" \
        "$(rx "test -e $(quote_arg "$p2pool_dir/.itest-marker") && echo present || echo gone")" "gone"
    assert_eq "reset never touched the unapplied config-only dashboard dir (#139)" \
        "$(rx "test -e $(quote_arg "$decoy_dashboard") && echo present || echo absent")" "absent"
    assert_eq "reset never touched the unapplied config-only p2pool dir (#139)" \
        "$(rx "test -e $(quote_arg "$decoy_p2pool") && echo present || echo absent")" "absent"

    # #550: recreated dirs are owned by the container uid (APP_UID=1000) — the mkdir-then-chown
    # order this leg proves against a live filesystem, not a shadowed stub.
    assert_eq "recreated dashboard dir owned by APP_UID 1000 (#550)" \
        "$(rx "stat -c %u $(quote_arg "$dashboard_dir") 2>/dev/null")" "1000"
    assert_eq "recreated p2pool dir owned by APP_UID 1000 (#550)" \
        "$(rx "stat -c %u $(quote_arg "$p2pool_dir") 2>/dev/null")" "1000"
    assert_eq "recreated p2pool/stats dir owned by APP_UID 1000 (#550)" \
        "$(rx "stat -c %u $(quote_arg "$p2pool_dir/stats") 2>/dev/null")" "1000"

    # dashboard/p2pool actually come back healthy — not just that compose_up_checked returned 0.
    wait_status_ok 240 || true
    pithead status >/dev/null 2>&1
    assert_rc "status OK after reset-dashboard" "$?" "0"
    assert_eq "dashboard container healthy after reset" "$(service_state dashboard)" "running healthy"
    assert_eq "p2pool container running after reset" "$(svc_state_of "$(service_state p2pool)")" "running"

    # Chains untouched: height never rewinds, and the block at the pre-reset height is byte-for-byte
    # the same block after — proving the data dir survived rather than being wiped and resynced.
    local mtip2 mheight2
    mtip2="$(monero_chain_tip)"
    mheight2="${mtip2%% *}"
    if [ -n "$mblock_before" ] && chain_tip_valid "$mtip2"; then
        assert_num_ge "monerod height never rewound across reset-dashboard (#139)" "$mheight2" "$mheight"
        assert_eq "the pre-reset monero block is still the same block (chain untouched, #139)" \
            "$(monero_block_identity "$mheight")" "$mblock_before"
    else
        it_skip_leg "monero chain-untouched check" "monerod get_info unreachable before or after the reset" "missing"
    fi
    if [[ "$theight" =~ ^[0-9]+$ ]]; then
        local theight2
        theight2="$(jq_get "$(api_state)" '.sync.tari.current')"
        assert_num_ge "tari height never rewound across reset-dashboard" "$theight2" "$theight"
    fi

    # #557: force a REAL compose failure once and prove the friendly branch fires instead of a bare
    # errexit abort. A foreign container squatting the p2pool container_name blocks `docker compose
    # up` exactly like a real name conflict would.
    if [ -n "$blocker_image" ]; then
        it_step "forcing a real compose failure to exercise the #557 friendly-failure branch…"
        rx "docker rm -f p2pool >/dev/null 2>&1; docker create --name p2pool $(quote_arg "$blocker_image")" >/dev/null 2>&1
        local fail_out fail_rc
        fail_out="$(pithead reset-dashboard -y 2>&1)"
        fail_rc=$?
        rx "docker rm -f p2pool" >/dev/null 2>&1
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
        it_skip_leg "#557 forced compose-failure check" "could not read the dashboard container's image to build a name-clash blocker" "missing"
    fi
}
