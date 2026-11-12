# Preview what `apply` would change without touching .env, generated files, or containers (#33).
# Runs apply's own render-and-diff preamble against a throwaway staging file, prints the same
# describe_change preview, and stops before the commit. --porcelain prints machine-readable
# "FLAG<TAB>KEY<TAB>MSG" lines for the control runner. Progress logs go to stderr so stdout
# carries only the preview. Reads $CONFIG_FILE, so PITHEAD_CONFIG_FILE can point one invocation
# at a staged candidate config.
apply_dry_run() {
    local porcelain="$1"
    local newenv="$PITHEAD_ENV_DRYRUN"
    PITHEAD_DRY_RUN=1
    {
        validate_stratum_port_change
        PITHEAD_CONFIG_SET=1 parse_and_validate_config
        load_preserved_state
        if onion_missing "$P2POOL_ONION" || ! is_deployed; then
            error "Stack is not fully provisioned. Run '$0 setup' first."
        fi
        resolve_dashboard_host # non-interactive
        DEPLOYMENT_COMPLETED=true
        render_env "$newenv"
    } >&2

    local changed=() key old new line flag msg
    while IFS= read -r key; do
        [ -n "$key" ] && changed+=("$key")
    done < <(env_changed_keys "$ENV_FILE" "$newenv")

    if [ "${#changed[@]}" -eq 0 ]; then
        [ "$porcelain" -eq 0 ] && log "No configuration changes detected."
        rm -f "$newenv"
        return 0
    fi
    for key in "${changed[@]}"; do
        old=$(env_get_file "$ENV_FILE" "$key")
        new=$(env_get_file "$newenv" "$key")
        line=$(describe_change "$key" "$old" "$new")
        flag=${line%%$'\t'*}
        msg=${line#*$'\t'}
        [ -z "$msg" ] && continue # internal-only keys stay silent, same as apply
        if [ "$porcelain" -eq 1 ]; then
            printf '%s\t%s\t%s\n' "$flag" "$key" "$msg"
        elif [ "$flag" == "DEST" ] || [ "$flag" == "CONFIRM" ]; then
            # #719: CONFIRM is disruptive on the host too — warn, same as DEST.
            echo -e "  ${C_YELLOW}⚠ ${msg}${C_RESET}"
        else
            echo "  • ${msg}"
        fi
    done
    rm -f "$newenv"
}

# Regenerate every DERIVED file — .env, Caddyfile, service configs, host units — from
# config.json plus THIS program, touching no containers. The appliance's boot path runs this
# every boot (#790): derived files must never outlive the program that rendered them, and an
# A/B update swaps the whole program, so the derived layer is rebuilt by construction instead
# of inspected for staleness. Same preservation guarantees as apply: load_preserved_state
# keeps Tor onions, RPC credentials and the proxy token across the rewrite.
render_derived() {
    require_env
    ensure_onion_password
    parse_and_validate_config
    load_preserved_state
    ensure_directories
    resolve_dashboard_host # non-interactive
    reconcile_appliance_hostname
    DEPLOYMENT_COMPLETED=true
    render_env "$ENV_FILE"
    provision_node_onions
    inject_service_configs
    generate_caddyfile
    provision_onion_client_auth
    provision_control_runner
    provision_firewall_check_units || error "Firewall check units could not be provisioned."
    control_prune_results "${CONTROL_DIR:-$PWD/data/control}" # #1990: bounds results/ every boot (#790), not just per-request
    provision_ssh_access
    provision_console_login
    render_local_miner_config
    log "Derived configuration regenerated from config.json."
}

# #1265, the remedy half: doctor's prescription for a certificate the box's addresses outran is
# `./pithead apply`, and apply never reached the mint on an unchanged config — the mint lives in
# generate_caddyfile, which only the changed branch called, so the exact command doctor printed
# did nothing in exactly the state it was printed for. On an appliance the unchanged branch now
# re-renders the Caddyfile (the mint inside it is idempotent by SAN-set comparison, so an
# unchanged address list keeps the operator's trusted certificate) and restarts Caddy only when
# the certificate or the Caddyfile actually moved — the same file comparison the changed branch
# makes, never a key list. A DIY host runs Caddy's own CA and takes the old path untouched. The
# caller holds the mutation lock. A function so it is driven at tier 1 with a stubbed render.
apply_refresh_appliance_tls() { # -> prints one line when it restarted Caddy
    is_appliance || return 0
    local crt cert_before cert_after caddy_before caddy_after
    crt="$(appliance_tls_dir)/wizard.crt"
    cert_before=$(sha256sum "$crt" 2>/dev/null | cut -d' ' -f1)
    caddy_before=$(cat Caddyfile 2>/dev/null)
    generate_caddyfile
    cert_after=$(sha256sum "$crt" 2>/dev/null | cut -d' ' -f1)
    caddy_after=$(cat Caddyfile 2>/dev/null)
    [ "$cert_before" != "$cert_after" ] || [ "$caddy_before" != "$caddy_after" ] || return 0
    log "The dashboard certificate or the Caddyfile changed for this machine's current addresses — restarting caddy so it serves them."
    docker compose restart caddy
}

recover_dashboard_data_carry() { # <old-dir> <configured-new-dir> <resolved-new-dir> <apply-marker> <copy-published:0|1> <marker-preexisted:0|1>
    local old="$1" new="$2" target="$3" marker="$4" copy_published="$5" marker_preexisted="$6" active current_target cleanup_ok=1
    active=$(env_get_file "$ENV_FILE" DASHBOARD_DATA_DIR 2>/dev/null || true)
    if [ "$active" = "$old" ]; then
        if [ "$copy_published" -eq 1 ]; then
            current_target=$(cd "$new" 2>/dev/null && pwd -P) || true
            if [ "$current_target" != "$target" ]; then
                cleanup_ok=0
                warn "The new dashboard.data_dir no longer resolves to the copied directory; the retry marker was kept. Restore $new before re-running '$0 apply'."
            elif ! rm -f -- "$target/mining_data.db" "$target/mining_data.db-wal" \
                "$target/mining_data.db-shm" "$target/mining_data.db-journal"; then
                cleanup_ok=0
                warn "Could not remove the unpublished dashboard copy at $new; the retry marker was kept. Fix its permissions before re-running '$0 apply'."
            fi
        fi
        # A marker an earlier failed apply left still owes that apply's recreate; only ours is cleared.
        if [ "$cleanup_ok" -eq 1 ] && [ "$marker_preexisted" -eq 0 ]; then
            rm -f "$marker" || warn "Could not clear $marker; a later apply may repeat recovery."
        fi
    fi
    docker compose start dashboard >/dev/null 2>&1 ||
        warn "The dashboard could not restart after the interrupted data carry. Fix the error above, then re-run '$0 apply' (the recovery marker will retry it)."
}

apply_lock_revision() {
    mutation_lock_acquire apply
    local revision
    revision=$(sha256sum "$CONFIG_FILE" "$ENV_FILE") || error "Could not check the configuration revision."
    [ "$revision" = "$1" ] || error "Configuration changed while preparing apply. Re-run '$0 apply' to preview it again."
}

apply_publish_tari_secret() {
    if [ -f "${PITHEAD_ENV_STAGE}.tari-wallet-secret" ]; then
        mv -fT -- "${PITHEAD_ENV_STAGE}.tari-wallet-secret" "$PWD/data/tari-wallet-secret.env" ||
            error "Could not publish the Tari payout wallet secret."
    fi
}

apply_publish_env() {
    local previous="${PITHEAD_ENV_STAGE}.previous"
    ln -- "$ENV_FILE" "$previous" || error "Could not preserve the previous environment."
    PITHEAD_ENV_PREVIOUS="$previous"
    mv -fT -- "$PITHEAD_ENV_STAGE" "$ENV_FILE"
    apply_publish_tari_secret
    rm -f -- "$previous"
    PITHEAD_ENV_PREVIOUS=""
}

apply() {
    local lock_held=0 dashboard_carry_recovery=0 dashboard_carry_target=""
    local assume_yes=0 dry_run=0 porcelain=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        --dry-run) dry_run=1 ;;
        --porcelain) porcelain=1 ;;
        *) error "Unknown option for apply: $arg. Run '$0 help'." ;;
        esac
    done
    [ "$porcelain" -eq 1 ] && [ "$dry_run" -eq 0 ] && error "--porcelain only makes sense with --dry-run."

    require_env
    if [ "$dry_run" -eq 1 ]; then
        apply_dry_run "$porcelain"
        return 0
    fi
    validate_stratum_port_change
    ensure_onion_password
    PITHEAD_CONFIG_SET=1 parse_and_validate_config
    local revision
    revision=$(sha256sum "$CONFIG_FILE" "$ENV_FILE") || error "Could not read the configuration revision."
    load_preserved_state
    if onion_missing "$P2POOL_ONION" || ! is_deployed; then
        error "Stack is not fully provisioned. Run '$0 setup' first."
    fi

    ensure_directories
    resolve_dashboard_host # non-interactive
    DEPLOYMENT_COMPLETED=true

    local newenv="$PITHEAD_ENV_STAGE"
    render_env "$newenv" "${newenv}.tari-wallet-secret"

    local changed=() key
    while IFS= read -r key; do
        [ -n "$key" ] && changed+=("$key")
    done < <(env_changed_keys "$ENV_FILE" "$newenv")

    local apply_marker="${ENV_FILE}.apply-incomplete" incomplete=0 rearm_sync_gate=0
    [ -f "$apply_marker" ] && incomplete=1
    local caddy_marker="${ENV_FILE}.caddy-restart-pending" caddy_pending=0
    [ -f "$caddy_marker" ] && caddy_pending=1
    grep -qx rearm-tari-only "$apply_marker" 2>/dev/null && rearm_sync_gate=2
    grep -qx rearm-sync-gate "$apply_marker" 2>/dev/null && rearm_sync_gate=1

    local destructive=0 caddy_changed=0 caddy_before="" caddy_had=0 wallet_keys=() line flag msg old new
    local dashboard_data_dir_old=""
    if [ "${#changed[@]}" -gt 0 ]; then
        echo ""
        log "The following changes will be applied:"
        for key in "${changed[@]}"; do
            old=$(env_get_file "$ENV_FILE" "$key")
            new=$(env_get_file "$newenv" "$key")
            case "$key" in MONERO_WALLET_ADDRESS | TARI_WALLET_ADDRESS) wallet_keys+=("$key") ;; esac
            # #2360: remember the active dashboard.data_dir for the carry before .env publication.
            # The separate historical-default migration runs later, after service configuration.
            [ "$key" == "DASHBOARD_DATA_DIR" ] && dashboard_data_dir_old="$old"
            # Monero changes take precedence over Tari-only re-arms.
            case "$key" in
            MONERO_NODE_HOST | MONERO_RPC_PORT) rearm_sync_gate=1 ;;
            TARI_MODE | TARI_GRPC_ADDRESS) [ "$rearm_sync_gate" -eq 1 ] || rearm_sync_gate=2 ;;
            esac
            line=$(describe_change "$key" "$old" "$new")
            flag=${line%%$'\t'*}
            msg=${line#*$'\t'}
            [ -z "$msg" ] && continue # internal-only keys (e.g. the auth fingerprint) stay silent
            # CONFIRM (#719) is the dashboard's confirm-gated class, but on the HOST CLI it is just
            # as disruptive as DEST — warn and fold it into the y/N confirmation, same as before.
            if [ "$flag" == "DEST" ] || [ "$flag" == "CONFIRM" ]; then
                echo -e "  ${C_YELLOW}⚠ ${msg}${C_RESET}"
                destructive=1
            else
                echo "  • ${msg}"
            fi
        done
        echo ""

        if [ "${#wallet_keys[@]}" -gt 0 ] && [ "$assume_yes" -eq 0 ]; then
            local wkey wnew wallet_new8 wlabel
            for wkey in "${wallet_keys[@]}"; do
                wnew=$(env_get_file "$newenv" "$wkey")
                wallet_new8="${wnew: -8}" # never the full address — previews and prompts stay truncated
                [ "$wkey" == "MONERO_WALLET_ADDRESS" ] && wlabel="Monero" || wlabel="Tari"
                warn "The $wlabel payout wallet address is changing — ALL future $wlabel rewards go to the new address."
                warn "Confirm by typing the last 8 characters of the new address ($wallet_new8)."
                read -r -p "Confirm: " CONFIRM || true
                if [ "$CONFIRM" != "$wallet_new8" ]; then
                    rm -f "$newenv" "${newenv}.tari-wallet-secret"
                    log "Apply cancelled. No changes were made."
                    return 0
                fi
            done
        elif [ "$destructive" -eq 1 ] && [ "$assume_yes" -eq 0 ]; then
            warn "Some of the changes above (⚠) are disruptive."
            read -r -p "Proceed with applying these changes? (y/N): " CONFIRM || true
            if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                rm -f "$newenv" "${newenv}.tari-wallet-secret"
                log "Apply cancelled. No changes were made."
                return 0
            fi
        fi

        apply_lock_revision "$revision"
        lock_held=1
        local marker_stage
        marker_stage=$(mktemp "${apply_marker}.XXXXXX") || error "Could not stage the apply recovery marker."
        if ! {
            case "$rearm_sync_gate" in
            1) echo rearm-sync-gate ;;
            2) echo rearm-tari-only ;;
            *) : ;;
            esac >"$marker_stage" &&
                python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$marker_stage" "$apply_marker"
        }; then
            rm -f "$marker_stage"
            error "Could not publish the apply recovery marker."
        fi
        if { [ "$dashboard_data_dir_old" != "$PWD/data/dashboard" ] || [ "${DASHBOARD_DIR_IS_DEFAULT:-0}" -eq 0 ]; }; then
            if [ -n "$dashboard_data_dir_old" ] && [ -n "${DASHBOARD_DIR:-}" ] &&
                [ "$dashboard_data_dir_old" != "$DASHBOARD_DIR" ] && [ -f "$dashboard_data_dir_old/mining_data.db" ]; then
                dashboard_carry_target=$(cd "$DASHBOARD_DIR" && pwd -P) || error "Could not resolve the new dashboard.data_dir ($DASHBOARD_DIR)."
                dashboard_carry_recovery=1
                PITHEAD_DASHBOARD_CARRY_RECOVERY=("$dashboard_data_dir_old" "${DASHBOARD_DIR:-}" "$dashboard_carry_target" "$apply_marker" 0 "$incomplete")
                trap 'cleanup_env_staging; recover_dashboard_data_carry "${PITHEAD_DASHBOARD_CARRY_RECOVERY[@]}"' EXIT
            fi
            carry_dashboard_data_move "$dashboard_data_dir_old" "${DASHBOARD_DIR:-}"
            [ "$dashboard_carry_recovery" -eq 0 ] || PITHEAD_DASHBOARD_CARRY_RECOVERY[4]=1
        fi
        lan_guard_arm_transition "$newenv" || error "The LAN-only source rule could not be armed before changing .env."
        : >"$caddy_marker"
        apply_publish_env
    else
        rm -f "$newenv"
        if [ "$incomplete" -eq 0 ]; then
            # Host state may change without an .env diff: converge units and local_miner (#3090).
            apply_lock_revision "$revision"
            apply_publish_tari_secret
            if [ "$caddy_pending" -eq 1 ]; then
                generate_caddyfile
                docker compose restart caddy
                rm -f "$caddy_marker"
            fi
            provision_control_runner
            provision_firewall_check_units || error "Firewall check units could not be provisioned."
            reconcile_appliance_hostname
            apply_refresh_appliance_tls # #1265: the mint doctor sends the operator here for
            render_local_miner_config
            provision_local_miner || true
            log "No configuration changes detected. Nothing to apply."
            mutation_lock_release
            announce_dashboard_url
            return 0
        fi
        warn "A previous apply updated the config but did not finish recreating containers — retrying."
    fi

    if [ "$lock_held" -eq 0 ]; then
        apply_lock_revision "$revision"
        apply_publish_tari_secret
        lock_held=1
    fi
    provision_node_onions
    inject_service_configs
    if [ -f "Caddyfile" ]; then
        caddy_had=1
        caddy_before=$(cat "Caddyfile")
    fi
    generate_caddyfile
    if [ "$caddy_pending" -eq 1 ] || { [ "$caddy_had" -eq 1 ] && [ "$caddy_before" != "$(cat "Caddyfile" 2>/dev/null)" ]; }; then
        caddy_changed=1
    fi
    provision_onion_client_auth
    provision_control_runner
    provision_firewall_check_units || error "Firewall check units could not be provisioned."
    provision_ssh_access
    provision_console_login   # #33: converge the control-runner units on the (new) toggle
    render_local_miner_config # #796: the built-in miner's config is derived — keep it current

    log "Updating containers..."
    migrate_compose_project
    apply_tor_egress_firewall
    migrate_dashboard_data
    if [ "$rearm_sync_gate" -ne 0 ]; then
        { rearm_sync_gate_marker "$DASHBOARD_DIR" "$rearm_sync_gate" 2>/dev/null ||
            sudo bash -c "$(declare -f rearm_sync_gate_marker); rearm_sync_gate_marker \"\$1\" \"\$2\"" _ "$DASHBOARD_DIR" "$rearm_sync_gate"; } &&
            [ -f "$DASHBOARD_DIR/sync-gate-reset" ] && [ ! -L "$DASHBOARD_DIR/sync-gate-reset" ] ||
            error "Could not re-arm the sync gate ($DASHBOARD_DIR/sync-gate-reset); re-run '$0 apply' to retry."
    fi
    # Recreate changed services; compose_up_checked also removes inactive profiles (#795).
    if ! compose_up_checked -d --remove-orphans; then
        warn "Config files were updated but containers were NOT recreated ('docker compose up' failed)."
        warn "Fix the cause shown above, then re-run '$0 apply' (it will retry the recreate) — or '$0 up'."
        # A recreate that failed mid-stop leaves the dashboard stopped, and with it the terminal
        # result the operator is waiting on (#3300). Bring only it back; the failure still stands.
        compose_up_checked -d --no-deps dashboard ||
            warn "The dashboard could not be restarted either — run '$0 up' to bring it back."
        exit 1 # leave $apply_marker in place so the retry re-attempts the recreate
    fi
    if [ "$dashboard_carry_recovery" -eq 1 ]; then
        trap cleanup_env_staging EXIT
        unset PITHEAD_DASHBOARD_CARRY_RECOVERY
    fi
    reconcile_appliance_hostname
    # Caddy mounts the Caddyfile read-only, so a content change alone won't recreate it.
    if [ "$caddy_changed" -eq 1 ]; then
        docker compose restart caddy
    fi
    # If the dashboard onion was just turned on, the recreated tor container generated its hostname;
    # read it back into .env so `pithead status` can surface the address (#343) — and regenerate the
    # Caddyfile + restart caddy so the HTTPS onion vhost (#360) actually appears this run instead of
    # never (#546): a re-render off the committed .env sees no change and no-ops before ever reaching
    # generate_caddyfile above.
    if [ "${DASHBOARD_ONION_ENABLED:-false}" == "true" ] && onion_missing "${DASHBOARD_ONION:-}"; then
        if provision_dashboard_onion && render_env; then
            generate_caddyfile
            docker compose restart caddy
            refresh_dashboard_onion_runtime
        fi
    fi
    rm -f "$apply_marker" "$caddy_marker"
    # Converge the built-in miner on a toggle without waiting for a reboot (#796): start it when
    # local_miner just turned on, stop it when it turned off. After the recreate above so the
    # stratum the miner dials is the freshly-applied one. Best-effort, same posture as setup.
    provision_local_miner || true
    log "Configuration applied."
    announce_dashboard_url
    mutation_lock_release
}
