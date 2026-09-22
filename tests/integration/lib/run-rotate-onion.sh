# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

# The EXIT trap must see these: the hidden-service identity is outside config.json/.env.
ROTATE_ONION_RESTORE_ARMED=0
ROTATE_ONION_HS_DIR=""
ROTATE_ONION_BACKUP_DIR=""
ROTATE_ONION_ENV_BACKUP=""
ROTATE_ONION_OLD_ADDRESS=""
ROTATE_ONION_OLD_KEY_FP=""
ROTATE_ONION_OLD_ENV_FP=""

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
    rx "set -e
        for key in $(quote_arg "$dir/hs_ed25519_secret_key") $(quote_arg "$dir/hs_ed25519_public_key"); do
            sudo -n test -f \"\$key\" && sudo -n test ! -L \"\$key\" || exit 1
        done
        secret=\$(sudo -n sha256sum $(quote_arg "$dir/hs_ed25519_secret_key") 2>/dev/null)
        public=\$(sudo -n sha256sum $(quote_arg "$dir/hs_ed25519_public_key") 2>/dev/null)
        printf '%s\n%s\n' \"\$secret\" \"\$public\" | sha256sum | cut -d' ' -f1"
}

rotate_onion_client_key_fingerprint() {
    local env_file="${1:-.env}"
    rx "set -e
        sudo -n test -f $(quote_arg "$env_file") && sudo -n test ! -L $(quote_arg "$env_file") || exit 1
        key=\$(sudo -n awk -F= '
            \$1 == \"DASHBOARD_ONION_CLIENT_PRIVKEY\" {
                value = substr(\$0, index(\$0, \"=\") + 1); count++; print value
            }
            END {
                if (count != 1 || value == \"\" || value == \"placeholder\") exit 1
            }
        ' $(quote_arg "$env_file"))
        printf '%s' \"\$key\" | sha256sum | cut -d' ' -f1"
}

rotate_onion_env_fingerprint() {
    local env_file="$1" exact="${2:-0}" ownership_check=""
    if [ "$exact" = 1 ]; then
        ownership_check="test -O $(quote_arg "$env_file") && mode=\$(stat -c %a $(quote_arg "$env_file") 2>/dev/null || stat -f %Lp $(quote_arg "$env_file")) && test \"\$mode\" = 600 || exit 1"
    fi
    rx "set -e
        test -f $(quote_arg "$env_file") && test ! -L $(quote_arg "$env_file") || exit 1
        $ownership_check
        lines=\$(awk -F= -v exact=$exact '
            \$1 == \"DASHBOARD_ONION_ADDRESS\" ||
            \$1 == \"DASHBOARD_ONION_CLIENT_PUBKEY\" ||
            \$1 == \"DASHBOARD_ONION_CLIENT_PRIVKEY\" {
                value = substr(\$0, index(\$0, \"=\") + 1)
                if (value == \"\" || value == \"placeholder\" || ++seen[\$1] != 1) exit 1
                print
                next
            }
            exact { exit 1 }
            END {
                if (seen[\"DASHBOARD_ONION_ADDRESS\"] != 1 ||
                    seen[\"DASHBOARD_ONION_CLIENT_PUBKEY\"] != 1 ||
                    seen[\"DASHBOARD_ONION_CLIENT_PRIVKEY\"] != 1) exit 1
            }
        ' $(quote_arg "$env_file"))
        printf '%s\n' \"\$lines\" | LC_ALL=C sort | sha256sum | cut -d' ' -f1"
}

rotate_onion_mining_fingerprint() {
    local dir="$1"
    rx "set -e
        records=
        for svc in p2pool monero tari; do
            service_dir=$(quote_arg "$dir")/\$svc
            sudo -n test -d \"\$service_dir\" || continue
            sudo -n test ! -L \"\$service_dir\"
            for key in \"\$service_dir/hs_ed25519_secret_key\" \"\$service_dir/hs_ed25519_public_key\"; do
                sudo -n test -f \"\$key\" && sudo -n test ! -L \"\$key\" || exit 1
            done
            secret=\$(sudo -n sha256sum \"\$service_dir/hs_ed25519_secret_key\" 2>/dev/null) || exit 1
            public=\$(sudo -n sha256sum \"\$service_dir/hs_ed25519_public_key\" 2>/dev/null) || exit 1
            records=\"\$records\$svc:\$secret:\$public
\"
        done
        test -n \"\$records\"
        printf '%s' \"\$records\" | sha256sum | cut -d' ' -f1"
}

wait_onion_retired() {
    local onion="$1" saved_env="$2" attempts=0 rc env_fp
    env_fp="$(rotate_onion_env_fingerprint "$saved_env" 1)" || return 3
    [ "$env_fp" = "$ROTATE_ONION_OLD_ENV_FP" ] || return 3
    while [ "$attempts" -lt 8 ]; do
        if _onion_reachable_external "$onion" "$saved_env"; then
            attempts=$((attempts + 1))
            [ "$attempts" -lt 8 ] && sleep 15
            continue
        else
            rc=$?
        fi
        [ "$rc" = 1 ] && return 0
        return "$rc"
    done
    return 4
}

rotate_onion_restore() {
    [ "$ROTATE_ONION_RESTORE_ARMED" = "1" ] || return 0
    local has_snapshot=0 snapshot_fp current_fp key_fp
    if snapshot_fp="$(rotate_onion_env_fingerprint "$ROTATE_ONION_ENV_BACKUP" 1)" && [ "$snapshot_fp" = "$ROTATE_ONION_OLD_ENV_FP" ]; then
        has_snapshot=1
    elif rx "test -e $(quote_arg "$ROTATE_ONION_ENV_BACKUP") || test -L $(quote_arg "$ROTATE_ONION_ENV_BACKUP")"; then
        return 1
    elif ! current_fp="$(rotate_onion_env_fingerprint .env)" || [ "$current_fp" != "$ROTATE_ONION_OLD_ENV_FP" ]; then
        return 1
    fi
    rx "
        set -e
        if sudo test -d $(quote_arg "$ROTATE_ONION_BACKUP_DIR") && sudo test ! -L $(quote_arg "$ROTATE_ONION_BACKUP_DIR"); then
            docker compose stop tor >/dev/null 2>&1 || true
            sudo rm -rf $(quote_arg "$ROTATE_ONION_HS_DIR")
            sudo mv $(quote_arg "$ROTATE_ONION_BACKUP_DIR") $(quote_arg "$ROTATE_ONION_HS_DIR")
        elif sudo test -e $(quote_arg "$ROTATE_ONION_BACKUP_DIR") || sudo test -L $(quote_arg "$ROTATE_ONION_BACKUP_DIR"); then exit 1; fi
        if [ $has_snapshot = 1 ]; then
            umask 077
            env_tmp=.env.itest.\$\$
            trap 'rm -f \"\$env_tmp\"' EXIT
            awk -F= '
                NR == FNR { saved[\$1] = \$0; count++; next }
                \$1 in saved {
                    print saved[\$1]
                    if (!(\$1 in replaced)) { replaced[\$1] = 1; replaced_count++ }
                    next
                }
                { print }
                END {
                    if (count != 3 || replaced_count != 3) exit 1
                }
            ' $(quote_arg "$ROTATE_ONION_ENV_BACKUP") .env > \"\$env_tmp\"
            chmod 600 \"\$env_tmp\"
            test -O \"\$env_tmp\" && test \"\$(stat -c %a \"\$env_tmp\")\" = 600
            mv \"\$env_tmp\" .env
            trap - EXIT
        fi
        docker compose up -d tor >/dev/null 2>&1
    " >/dev/null 2>&1 || return 1
    key_fp="$(rotate_onion_key_fingerprint "$ROTATE_ONION_HS_DIR")" || return 1
    [ "$key_fp" = "$ROTATE_ONION_OLD_KEY_FP" ] || return 1
    [ "$(rx "sudo test -f $(quote_arg "$ROTATE_ONION_HS_DIR/hostname") && sudo test ! -L $(quote_arg "$ROTATE_ONION_HS_DIR/hostname") && sudo cat $(quote_arg "$ROTATE_ONION_HS_DIR/hostname") 2>/dev/null")" = "$ROTATE_ONION_OLD_ADDRESS" ] || return 1
    current_fp="$(rotate_onion_env_fingerprint .env)" || return 1
    [ "$current_fp" = "$ROTATE_ONION_OLD_ENV_FP" ] || return 1
    pithead render >/dev/null 2>&1 &&
        rx "docker compose restart caddy >/dev/null 2>&1" >/dev/null 2>&1 || return 1
    wait_status_ok 120 && _onion_reachable_external "$ROTATE_ONION_OLD_ADDRESS" || return 1
    if [ "$has_snapshot" = 1 ]; then
        rx "rm -f $(quote_arg "$ROTATE_ONION_ENV_BACKUP") && test ! -e $(quote_arg "$ROTATE_ONION_ENV_BACKUP") && test ! -L $(quote_arg "$ROTATE_ONION_ENV_BACKUP")" >/dev/null 2>&1 || return 1
    fi
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

    if [ "$IT_MODE" != local ] || [[ "${IT_ROTATE_ONION_FIXTURE_ATTESTATION:-}" != /* ]]; then
        it_fail "reserved onion fixture is supplied by the e2e launcher" "direct harness runs cannot rotate an identity"
        return 1
    fi

    local tor_data_dir hs_dir backup_dir env_backup old_key_fp old_client_fp old_env_fp old_mining_fp
    tor_data_dir="$(rotate_onion_data_dir "$(env_on_box TOR_DATA_DIR)")"
    hs_dir="$tor_data_dir/dashboard"
    backup_dir="$tor_data_dir/dashboard.itest-preserve"
    env_backup="backups/rotate-onion-env-preserve"
    if [ -z "$tor_data_dir" ] || [ "$tor_data_dir" != "$IT_ROTATE_ONION_FIXTURE_ATTESTATION" ] || ! rx "
        set -e
        marker=$(quote_arg "$tor_data_dir.attestation")
        sudo -n test -f \"\$marker\" && sudo -n test ! -L \"\$marker\"
        test \"\$(sudo -n stat -c %u \"\$marker\")\" = 0
        test \"\$(sudo -n stat -c %a \"\$marker\")\" = 600
        test \"\$(sudo -n cat \"\$marker\")\" = $(quote_arg "$tor_data_dir")
        sudo -n test -d $(quote_arg "$hs_dir") && sudo -n test ! -L $(quote_arg "$hs_dir")
    "; then
        it_fail "isolated onion fixture is bound to its protected launcher marker" "refusing to rotate an unmarked or mismatched TOR_DATA_DIR"
        return 1
    fi
    if [ "$(env_on_box DASHBOARD_ONION_ENABLED)" != "true" ]; then
        it_fail "isolated dashboard onion fixture is enabled" "the explicitly selected rotate-onion phase requires its reserved fixture"
        return 1
    fi
    local old_onion
    old_onion="$(env_on_box DASHBOARD_ONION_ADDRESS)"
    if [ -z "$old_onion" ] || [ "$old_onion" = "placeholder" ]; then
        it_fail "isolated dashboard onion fixture is provisioned" "the explicitly selected rotate-onion phase requires a real fixture identity"
        return 1
    fi
    if [ "$(env_on_box DASHBOARD_ONION_CLIENT_AUTH)" != "true" ]; then
        it_fail "isolated dashboard onion fixture has client authorization" "the phase must prove the client-auth key changes"
        return 1
    fi

    it_step "external Tor client: reach the dashboard onion before rotating (baseline)…"
    if ! _onion_reachable_external; then
        it_fail "isolated dashboard onion fixture is externally reachable before rotation" "the explicit phase cannot prove rotation from an unreachable baseline"
        return 1
    fi

    if ! rx '
        set -e -o pipefail
        mkdir -p backups
        test -d backups && test ! -L backups && test -O backups
        snapshot_dir=$(readlink -f backups)
        cids=$(docker compose ps --all -q)
        test -n "$cids"
        mount_sources=$(for cid in $cids; do
            docker inspect --format "{{range .Mounts}}{{println .Source}}{{end}}" "$cid" || exit 1
        done)
        while IFS= read -r source; do
            [ -n "$source" ] || continue
            [ "$source" != / ] || exit 1
            case "$snapshot_dir/" in "$source"/*) exit 1 ;; esac
        done <<<"$mount_sources"
    '; then
        it_fail "client credential backup has an owner-only host directory" "refusing to place the credential in a container-mounted or unowned directory"
        return 1
    fi
    if ! old_key_fp="$(rotate_onion_key_fingerprint "$hs_dir")" ||
        ! old_client_fp="$(rotate_onion_client_key_fingerprint)" ||
        ! old_env_fp="$(rotate_onion_env_fingerprint .env)" ||
        ! old_mining_fp="$(rotate_onion_mining_fingerprint "$tor_data_dir")" ||
        [ -z "$old_key_fp" ] || [ -z "$old_client_fp" ] || [ -z "$old_env_fp" ] || [ -z "$old_mining_fp" ]; then
        it_fail "fixture identity is readable before rotation" "refusing to rotate hidden-service or client-auth keys that cannot be verified"
        return 1
    fi

    it_step "backing up the pre-rotation onion directory…"
    if ! rx "
        set -e -o pipefail
        if sudo -n test -e $(quote_arg "$backup_dir") || sudo -n test -L $(quote_arg "$backup_dir") ||
            test -e $(quote_arg "$env_backup") || test -L $(quote_arg "$env_backup"); then exit 2; fi
        umask 077
        env_tmp=$(quote_arg "$env_backup").tmp.\$\$
        made_env=0 made_hs=0
        {
            awk -F= '
                \$1 == \"DASHBOARD_ONION_ADDRESS\" ||
                \$1 == \"DASHBOARD_ONION_CLIENT_PUBKEY\" ||
                \$1 == \"DASHBOARD_ONION_CLIENT_PRIVKEY\" { print }
            ' .env > \"\$env_tmp\" &&
                chmod 600 \"\$env_tmp\" &&
                test -O \"\$env_tmp\" && test \"\$(stat -c %a \"\$env_tmp\")\" = 600 &&
                ln \"\$env_tmp\" $(quote_arg "$env_backup") && made_env=1 &&
                rm -f \"\$env_tmp\" && made_hs=1 &&
                sudo -n cp -aT $(quote_arg "$hs_dir") $(quote_arg "$backup_dir")
        } || {
            rc=\$?
            rm -f \"\$env_tmp\"
            test \"\$made_env\" = 0 || rm -f $(quote_arg "$env_backup")
            test \"\$made_hs\" = 0 || sudo -n rm -rf -- $(quote_arg "$backup_dir")
            exit \"\$rc\"
        }
    "; then
        it_fail "pre-rotation identity backup created" "an existing recovery path was preserved or a partial new copy was removed"
        return 1
    fi
    local backup_env_fp
    if ! backup_env_fp="$(rotate_onion_env_fingerprint "$env_backup" 1)" || [ "$backup_env_fp" != "$old_env_fp" ]; then
        rx "rm -f $(quote_arg "$env_backup") && sudo -n rm -rf -- $(quote_arg "$backup_dir")" >/dev/null 2>&1 || {
            it_fail "invalid pre-rotation backup is removed" "the unusable credential copy could not be deleted"
            return 1
        }
        it_fail "pre-rotation credential backup matches the original" "the incomplete copy was removed before any identity changed"
        return 1
    fi
    ROTATE_ONION_HS_DIR="$hs_dir"
    ROTATE_ONION_BACKUP_DIR="$backup_dir"
    ROTATE_ONION_ENV_BACKUP="$env_backup"
    ROTATE_ONION_OLD_ADDRESS="$old_onion"
    ROTATE_ONION_OLD_KEY_FP="$old_key_fp"
    ROTATE_ONION_OLD_ENV_FP="$old_env_fp"
    # Arm last: before this assignment no identity has changed; after it every restore input is set.
    ROTATE_ONION_RESTORE_ARMED=1

    it_step "rotating the dashboard onion…"
    pithead rotate-dashboard-onion -y >/dev/null 2>&1
    assert_rc "rotate-dashboard-onion completes" "$?" "0"

    local new_onion new_client_fp current_mining_fp restored_key_fp
    new_onion="$(env_on_box DASHBOARD_ONION_ADDRESS)"
    new_client_fp="$(rotate_onion_client_key_fingerprint)" || new_client_fp=""
    assert_ne "rotate mints a new onion address" "$new_onion" "$old_onion"
    assert_ne "rotated address is not the placeholder" "$new_onion" "placeholder"
    assert_ne "HOST_IP resolved after rotate — no unbound variable (#356)" "$(env_on_box HOST_IP)" ""
    assert_eq "DEPLOYMENT_COMPLETED survives rotate — next apply doesn't demand setup again (#356)" \
        "$(env_on_box DEPLOYMENT_COMPLETED)" "true"
    if [ -n "$new_client_fp" ] && [ "$new_client_fp" != "$old_client_fp" ]; then
        it_pass "rotate mints a new client-auth key"
    else
        it_fail "rotate mints a new client-auth key" "the client-auth private key did not change"
    fi
    if current_mining_fp="$(rotate_onion_mining_fingerprint "$tor_data_dir")" && [ "$current_mining_fp" = "$old_mining_fp" ]; then
        it_pass "rotation leaves every mining hidden-service identity unchanged"
    else
        it_fail "rotation leaves every mining hidden-service identity unchanged" "a mining hidden-service key changed or became unreadable"
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
    if wait_onion_retired "$old_onion" "$env_backup"; then
        it_pass "old dashboard onion stops answering after rotation"
    else
        it_fail "old dashboard onion stops answering after rotation" "the retired address still answered or the independent Tor probe could not establish a trustworthy verdict"
    fi

    it_step "restoring the pre-rotation onion directory…"
    if rotate_onion_restore; then
        it_pass "pre-rotation onion directory restored"
    else
        it_fail "pre-rotation onion directory restored" "the restore command failed on the box — check for a leftover $backup_dir holding the retired keys"
    fi
    if restored_key_fp="$(rotate_onion_key_fingerprint "$hs_dir")" && [ "$restored_key_fp" = "$old_key_fp" ]; then
        it_pass "restored hidden-service key fingerprint matches the original"
    else
        it_fail "restored hidden-service key fingerprint matches the original" "the key fingerprint changed"
    fi
    if current_mining_fp="$(rotate_onion_mining_fingerprint "$tor_data_dir")" && [ "$current_mining_fp" = "$old_mining_fp" ]; then
        it_pass "restored fixture keeps every mining hidden-service identity unchanged"
    else
        it_fail "restored fixture keeps every mining hidden-service identity unchanged" "a mining hidden-service key changed or became unreadable"
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
