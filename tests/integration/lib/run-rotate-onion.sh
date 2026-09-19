# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

# Tier-4 leg for `rotate-dashboard-onion` (#2345): 0 invocations under tests/integration or
# tests/os before this — tier-1 only ever runs it sourced against a stubbed engine. This proves,
# on a real box: the new address answers over the real Tor network, the OLD address stops
# answering (its hidden-service keys were wiped, not just re-keyed), the Caddyfile names only the
# new vhost (#546's regression), HOST_IP survives (#356's regression), and the client-auth key
# actually changed. It then restores the pre-rotation onion identity itself — the end-of-run
# config restore only reverts config.json/.env, and the onion's real identity is the ed25519 key
# files under TOR_DATA_DIR, which live outside both.
run_rotate_onion() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="rotate-onion"
    echo ""
    it_log "── rotate-dashboard-onion phase (#2345) ─────────────"

    if [ "$(env_on_box DASHBOARD_ONION_ENABLED)" != "true" ]; then
        it_skip_phase "rotate-onion" "dashboard onion not enabled on this box" "by-design"
        return 0
    fi
    local old_onion
    old_onion="$(env_on_box DASHBOARD_ONION_ADDRESS)"
    if [ -z "$old_onion" ] || [ "$old_onion" = "placeholder" ]; then
        it_skip_phase "rotate-onion" "dashboard onion not provisioned on this box" "by-design"
        return 0
    fi

    it_step "external Tor client: reach the dashboard onion before rotating (baseline)…"
    if ! _onion_reachable_external; then
        it_skip_leg "rotate-dashboard-onion (#2345)" "onion not reachable from outside before rotating (live Tor network) — can't prove the rotation"
        return 0
    fi

    local client_auth old_pub old_priv tor_data_dir hs_dir backup_dir
    client_auth="$(env_on_box DASHBOARD_ONION_CLIENT_AUTH)"
    old_pub="$(env_on_box DASHBOARD_ONION_CLIENT_PUBKEY)"
    old_priv="$(env_on_box DASHBOARD_ONION_CLIENT_PRIVKEY)"
    tor_data_dir="$(env_on_box TOR_DATA_DIR)"
    hs_dir="$tor_data_dir/dashboard"
    backup_dir="$tor_data_dir/dashboard.itest-preserve"

    it_step "backing up the pre-rotation onion directory…"
    if ! rx "sudo rm -rf $(quote_arg "$backup_dir") && sudo cp -a $(quote_arg "$hs_dir") $(quote_arg "$backup_dir")"; then
        it_skip_phase "rotate-onion" "could not back up $hs_dir before rotating — refusing to rotate what we can't restore" "missing"
        return 0
    fi

    it_step "rotating the dashboard onion…"
    pithead rotate-dashboard-onion -y >/dev/null 2>&1
    assert_rc "rotate-dashboard-onion completes" "$?" "0"

    local new_onion new_priv
    new_onion="$(env_on_box DASHBOARD_ONION_ADDRESS)"
    new_priv="$(env_on_box DASHBOARD_ONION_CLIENT_PRIVKEY)"
    assert_ne "rotate mints a new onion address" "$new_onion" "$old_onion"
    assert_ne "rotated address is not the placeholder" "$new_onion" "placeholder"
    assert_ne "HOST_IP resolved after rotate — no unbound variable (#356)" "$(env_on_box HOST_IP)" ""
    assert_eq "DEPLOYMENT_COMPLETED survives rotate — next apply doesn't demand setup again (#356)" \
        "$(env_on_box DEPLOYMENT_COMPLETED)" "true"
    if [ "$client_auth" = "true" ]; then
        assert_ne "rotate mints a new client-auth key" "$new_priv" "$old_priv"
    fi

    local caddy_content
    caddy_content="$(rx "cat Caddyfile 2>/dev/null")"
    case "$caddy_content" in
    *"$new_onion"*) it_pass "Caddyfile names the new onion's vhost" ;;
    *) it_fail "Caddyfile names the new onion's vhost" "Caddyfile does not mention $new_onion" ;;
    esac
    case "$caddy_content" in
    *"$old_onion"*) it_fail "Caddyfile drops the retired onion's vhost (#546)" "Caddyfile still mentions $old_onion" ;;
    *) it_pass "Caddyfile drops the retired onion's vhost (#546)" ;;
    esac

    it_step "external Tor client: the NEW onion must answer…"
    if _onion_reachable_external; then
        it_pass "new dashboard onion reachable from outside after rotation"
    else
        it_fail "new dashboard onion reachable from outside after rotation" "external client could not reach the new onion within the probe window"
    fi

    it_step "external Tor client: the OLD onion must have stopped answering…"
    if _onion_reachable_external "$old_onion"; then
        it_fail "old dashboard onion stops answering after rotation" "external client could still reach the retired address"
    else
        it_pass "old dashboard onion stops answering after rotation"
    fi

    # Restore the pre-rotation onion identity. A v3 onion address is DERIVED from its ed25519 key,
    # so swapping the old key files back reproduces the exact old address with no need to poll tor
    # for it — write it straight into .env alongside the old client-auth keypair. `apply -y` is
    # NOT used here: it diffs the fresh render against the live .env and no-ops when nothing
    # differs (env_changed_keys, lib/pithead/40-apply-and-render.sh), and by the time this .env
    # write lands there is nothing left to diff. `render` regenerates every derived file
    # (Caddyfile, authorized_clients) unconditionally from .env instead — it touches no
    # containers, so caddy still needs its own explicit restart to pick up the file it wrote.
    it_step "restoring the pre-rotation onion directory…"
    rx "
        docker compose stop tor >/dev/null 2>&1 || true
        sudo rm -rf $(quote_arg "$hs_dir")
        sudo mv $(quote_arg "$backup_dir") $(quote_arg "$hs_dir")
        awk -v a=$(quote_arg "$old_onion") -v pk=$(quote_arg "$old_pub") -v pv=$(quote_arg "$old_priv") '
            /^DASHBOARD_ONION_ADDRESS=/        { print \"DASHBOARD_ONION_ADDRESS=\" a; next }
            /^DASHBOARD_ONION_CLIENT_PUBKEY=/  { print \"DASHBOARD_ONION_CLIENT_PUBKEY=\" pk; next }
            /^DASHBOARD_ONION_CLIENT_PRIVKEY=/ { print \"DASHBOARD_ONION_CLIENT_PRIVKEY=\" pv; next }
            { print }
        ' .env > .env.itest && mv .env.itest .env
        docker compose up -d tor >/dev/null 2>&1
    " >/dev/null 2>&1
    pithead render >/dev/null 2>&1
    rx "docker compose restart caddy >/dev/null 2>&1" >/dev/null 2>&1
    wait_status_ok 120 || true
    assert_eq "the previous onion address is restored" "$(env_on_box DASHBOARD_ONION_ADDRESS)" "$old_onion"
    pithead status >/dev/null 2>&1
    assert_rc "stack healthy after restoring the pre-rotation onion" "$?" "0"
}
