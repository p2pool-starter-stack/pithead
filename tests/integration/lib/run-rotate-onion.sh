# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

# The EXIT trap must see these: the hidden-service identity is outside config.json/.env.
ROTATE_ONION_RESTORE_ARMED=0
ROTATE_ONION_HS_DIR=""
ROTATE_ONION_BACKUP_DIR=""
ROTATE_ONION_OLD_ADDRESS=""
ROTATE_ONION_OLD_PUBKEY=""
ROTATE_ONION_OLD_PRIVKEY=""
ROTATE_ONION_OLD_KEY_FP=""

rotate_onion_data_dir() {
    local raw="$1" canonical
    case "$raw" in /*) ;; *) return 1 ;; esac
    [ "$raw" != "/" ] || return 1
    canonical="$(rx "sudo -n test -d $(quote_arg "$raw") && sudo -n test ! -L $(quote_arg "$raw") && sudo -n readlink -f -- $(quote_arg "$raw")")" || return 1
    [ "$canonical" = "$raw" ] || return 1
    printf '%s\n' "$canonical"
}

rotate_onion_key_fingerprint() {
    local dir="$1"
    rx "set -e -o pipefail
        for key in $(quote_arg "$dir/hs_ed25519_secret_key") $(quote_arg "$dir/hs_ed25519_public_key"); do
            sudo -n test -f \"\$key\" && sudo -n test ! -L \"\$key\"
        done
        sudo -n sha256sum $(quote_arg "$dir/hs_ed25519_secret_key") $(quote_arg "$dir/hs_ed25519_public_key") 2>/dev/null | sha256sum | cut -d' ' -f1"
}

rotate_onion_restore() {
    [ "$ROTATE_ONION_RESTORE_ARMED" = "1" ] || return 0
    rx "
        set -e
        if sudo test -d $(quote_arg "$ROTATE_ONION_BACKUP_DIR") && sudo test ! -L $(quote_arg "$ROTATE_ONION_BACKUP_DIR"); then
            docker compose stop tor >/dev/null 2>&1 || true
            sudo rm -rf $(quote_arg "$ROTATE_ONION_HS_DIR")
            sudo mv $(quote_arg "$ROTATE_ONION_BACKUP_DIR") $(quote_arg "$ROTATE_ONION_HS_DIR")
        elif sudo test -e $(quote_arg "$ROTATE_ONION_BACKUP_DIR") || sudo test -L $(quote_arg "$ROTATE_ONION_BACKUP_DIR"); then exit 1; fi
        awk -v a=$(quote_arg "$ROTATE_ONION_OLD_ADDRESS") -v pk=$(quote_arg "$ROTATE_ONION_OLD_PUBKEY") -v pv=$(quote_arg "$ROTATE_ONION_OLD_PRIVKEY") '
            /^DASHBOARD_ONION_ADDRESS=/        { print \"DASHBOARD_ONION_ADDRESS=\" a; next }
            /^DASHBOARD_ONION_CLIENT_PUBKEY=/  { print \"DASHBOARD_ONION_CLIENT_PUBKEY=\" pk; next }
            /^DASHBOARD_ONION_CLIENT_PRIVKEY=/ { print \"DASHBOARD_ONION_CLIENT_PRIVKEY=\" pv; next }
            { print }
        ' .env > .env.itest
        mv .env.itest .env
        docker compose up -d tor >/dev/null 2>&1
    " >/dev/null 2>&1 || return 1
    [ "$(rotate_onion_key_fingerprint "$ROTATE_ONION_HS_DIR")" = "$ROTATE_ONION_OLD_KEY_FP" ] || return 1
    [ "$(rx "sudo test -f $(quote_arg "$ROTATE_ONION_HS_DIR/hostname") && sudo test ! -L $(quote_arg "$ROTATE_ONION_HS_DIR/hostname") && sudo cat $(quote_arg "$ROTATE_ONION_HS_DIR/hostname") 2>/dev/null")" = "$ROTATE_ONION_OLD_ADDRESS" ] || return 1
    pithead render >/dev/null 2>&1 &&
        rx "docker compose restart caddy >/dev/null 2>&1" >/dev/null 2>&1 || return 1
    wait_status_ok 120 && _onion_reachable_external "$ROTATE_ONION_OLD_ADDRESS" || return 1
    ROTATE_ONION_RESTORE_ARMED=0
}

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

    local client_auth old_pub old_priv tor_data_dir hs_dir backup_dir old_key_fp
    client_auth="$(env_on_box DASHBOARD_ONION_CLIENT_AUTH)"
    old_pub="$(env_on_box DASHBOARD_ONION_CLIENT_PUBKEY)"
    old_priv="$(env_on_box DASHBOARD_ONION_CLIENT_PRIVKEY)"
    tor_data_dir="$(rotate_onion_data_dir "$(env_on_box TOR_DATA_DIR)")"
    hs_dir="$tor_data_dir/dashboard"
    backup_dir="$tor_data_dir/dashboard.itest-preserve"
    if [ -z "$tor_data_dir" ] || ! rx "sudo -n test -d $(quote_arg "$hs_dir") && sudo -n test ! -L $(quote_arg "$hs_dir")"; then
        it_skip_phase "rotate-onion" "TOR_DATA_DIR or its dashboard service directory is not a canonical directory — refusing to touch it" "missing"
        return 0
    fi
    old_key_fp="$(rotate_onion_key_fingerprint "$hs_dir")"
    if [ -z "$old_key_fp" ]; then
        it_skip_phase "rotate-onion" "dashboard hidden-service key files are unreadable — refusing to rotate what cannot be verified" "missing"
        return 0
    fi

    it_step "backing up the pre-rotation onion directory…"
    if ! rx "sudo rm -rf $(quote_arg "$backup_dir") && sudo cp -a $(quote_arg "$hs_dir") $(quote_arg "$backup_dir")"; then
        it_skip_phase "rotate-onion" "could not back up $hs_dir before rotating — refusing to rotate what we can't restore" "missing"
        return 0
    fi
    ROTATE_ONION_RESTORE_ARMED=1
    ROTATE_ONION_HS_DIR="$hs_dir"
    ROTATE_ONION_BACKUP_DIR="$backup_dir"
    ROTATE_ONION_OLD_ADDRESS="$old_onion"
    ROTATE_ONION_OLD_PUBKEY="$old_pub"
    ROTATE_ONION_OLD_PRIVKEY="$old_priv"
    ROTATE_ONION_OLD_KEY_FP="$old_key_fp"

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
        # Not assert_ne: its failure message prints the compared values verbatim, and this one is
        # a live Tor client-auth PRIVATE key — assert_ne would hand it to bench-ci's retained job
        # log. Report only the boolean; the key itself never appears in output.
        if [ -n "$new_priv" ] && [ "$new_priv" != "$old_priv" ]; then
            it_pass "rotate mints a new client-auth key"
        else
            it_fail "rotate mints a new client-auth key" "the client-auth private key did not change"
        fi
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

    it_step "restoring the pre-rotation onion directory…"
    if rotate_onion_restore; then
        it_pass "pre-rotation onion directory restored"
    else
        it_fail "pre-rotation onion directory restored" "the restore command failed on the box — check for a leftover $backup_dir holding the retired keys"
    fi
    if [ "$(rotate_onion_key_fingerprint "$hs_dir")" = "$old_key_fp" ]; then
        it_pass "restored hidden-service key fingerprint matches the original"
    else
        it_fail "restored hidden-service key fingerprint matches the original" "the key fingerprint changed"
    fi
    assert_eq "Tor serves the restored hidden-service identity" "$(rx "sudo cat $(quote_arg "$hs_dir/hostname") 2>/dev/null")" "$old_onion"
    assert_eq "the previous onion address is restored" "$(env_on_box DASHBOARD_ONION_ADDRESS)" "$old_onion"
    case "$(rx "cat Caddyfile 2>/dev/null")" in
    *"$old_onion"*) it_pass "Caddyfile names the restored onion's vhost again" ;;
    *) it_fail "Caddyfile names the restored onion's vhost again" "Caddyfile does not mention $old_onion after restore" ;;
    esac
    [ "$ROTATE_ONION_RESTORE_ARMED" = 0 ] && it_pass "restored dashboard onion reachable from outside again"
    pithead status >/dev/null 2>&1
    assert_rc "stack healthy after restoring the pre-rotation onion" "$?" "0"
}
