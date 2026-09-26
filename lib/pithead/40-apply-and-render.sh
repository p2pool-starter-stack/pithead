# Preview what `apply` would change without touching .env, generated files, or containers (#33).
# Runs apply's own render-and-diff preamble against a throwaway staging file, prints the same
# describe_change preview, and stops before the commit. --porcelain prints machine-readable
# "FLAG<TAB>KEY<TAB>MSG" lines for the control runner. Progress logs go to stderr so stdout
# carries only the preview. Reads $CONFIG_FILE, so PITHEAD_CONFIG_FILE can point one invocation
# at a staged candidate config.
apply_dry_run() {
    local porcelain="$1"
    local newenv="${ENV_FILE}.dryrun"
    PITHEAD_DRY_RUN=1 # #556: parse_and_validate_config -> persist_node_credentials checks this
    {
        # NOTE: no ensure_onion_password here — it would write an auto-generated password into
        # the candidate config. A dry run must only read; an invalid candidate fails validation.
        PITHEAD_CONFIG_SET=1 parse_and_validate_config
        load_preserved_state
        # P2Pool's onion is the provisioning marker (see apply) — a node's may be a placeholder.
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

apply() {
    # apply reaches its mutating window down two different paths (a normal change, and the retry
    # after a previous apply committed the config but did not finish recreating containers), so it
    # tracks its own hold rather than acquiring twice — the depth counter would then never reach
    # zero and the lock would outlive the verb inside a single process.
    local lock_held=0 dashboard_carry_recovery=0 dashboard_carry_published=0 dashboard_carry_target=""
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
    ensure_onion_password # #343: auto-generate a dashboard password if the onion is on without one
    PITHEAD_CONFIG_SET=1 parse_and_validate_config
    load_preserved_state
    # P2Pool's onion is the provisioning marker, not Monero's: p2pool always runs, while a node's
    # onion is legitimately a placeholder in remote mode (#103).
    if onion_missing "$P2POOL_ONION" || ! is_deployed; then
        error "Stack is not fully provisioned. Run '$0 setup' first."
    fi

    ensure_directories
    resolve_dashboard_host # non-interactive
    DEPLOYMENT_COMPLETED=true

    # Render the new config to a staging file and diff it against the live .env, so we can
    # preview the changes and confirm anything disruptive before touching running containers.
    local newenv="${ENV_FILE}.new"
    render_env "$newenv"

    local changed=() key
    while IFS= read -r key; do
        [ -n "$key" ] && changed+=("$key")
    done < <(env_changed_keys "$ENV_FILE" "$newenv")

    # A marker left by a previous apply whose `docker compose up` failed AFTER the new config was
    # committed (#125): the stack then runs OLD containers against NEW config files, and because a
    # re-apply diffs the (already-committed) .env it would see no change and silently no-op. While
    # the marker is present, re-apply re-attempts the recreate even when the rendered config matches.
    local apply_marker="${ENV_FILE}.apply-incomplete" incomplete=0
    [ -f "$apply_marker" ] && incomplete=1

    local destructive=0 caddy_changed=0 caddy_before="" caddy_had=0 wallet_keys=() line flag msg old new
    local dashboard_data_dir_old="" rearm_sync_gate=0
    if [ "${#changed[@]}" -gt 0 ]; then
        echo ""
        log "The following changes will be applied:"
        for key in "${changed[@]}"; do
            old=$(env_get_file "$ENV_FILE" "$key")
            new=$(env_get_file "$newenv" "$key")
            # Payout-wallet change (#375): remember WHICH wallet keys change for the typed
            # confirmation below — one prompt per key, so a Monero+Tari double change can't
            # ride through on a single typed prefix.
            case "$key" in MONERO_WALLET_ADDRESS | TARI_WALLET_ADDRESS) wallet_keys+=("$key") ;; esac
            # #2360: remember the active dashboard.data_dir for the carry before .env publication.
            # The separate historical-default migration runs later, after service configuration.
            [ "$key" == "DASHBOARD_DATA_DIR" ] && dashboard_data_dir_old="$old"
            # #2763: a required chain now dials another node (remote<->local, a new endpoint)
            # that may not have synced, so the #35 release earned on the old node no longer holds.
            case "$key" in MONERO_NODE_HOST | MONERO_RPC_PORT | TARI_MODE | TARI_GRPC_ADDRESS) rearm_sync_gate=1 ;; esac
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
            # A payout-wallet change upgrades the generic y/N to a typed confirmation (#375):
            # every future reward goes to the new address, so the operator must type its first
            # 8 characters — once PER changed wallet key (a Monero and a Tari change are two
            # separate redirects; each needs its own typed confirm). This is the strongest
            # confirm, so it stands in for the y/N even when other disruptive changes ride
            # along. --yes keeps working for automation.
            local wkey wnew wallet_new8 wlabel
            for wkey in "${wallet_keys[@]}"; do
                wnew=$(env_get_file "$newenv" "$wkey")
                wallet_new8="${wnew:0:8}" # never the full address — previews and prompts stay truncated
                [ "$wkey" == "MONERO_WALLET_ADDRESS" ] && wlabel="Monero" || wlabel="Tari"
                warn "The $wlabel payout wallet address is changing — ALL future $wlabel rewards go to the new address."
                warn "Confirm by typing the first 8 characters of the new address ($wallet_new8)."
                read -r -p "Confirm: " CONFIRM || true
                if [ "$CONFIRM" != "$wallet_new8" ]; then
                    rm -f "$newenv"
                    log "Apply cancelled. No changes were made."
                    return 0
                fi
            done
        elif [ "$destructive" -eq 1 ] && [ "$assume_yes" -eq 0 ]; then
            warn "Some of the changes above (⚠) are disruptive."
            read -r -p "Proceed with applying these changes? (y/N): " CONFIRM || true
            if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                rm -f "$newenv"
                log "Apply cancelled. No changes were made."
                return 0
            fi
        fi

        # After every confirm above (the typed wallet redirect, the disruptive-change y/N):
        # carry the DB before the rendered .env switches its mount. A refusal therefore leaves
        # the active path unchanged, rather than stranding the stopped dashboard on a new path.
        mutation_lock_acquire apply
        lock_held=1
        if { [ "$dashboard_data_dir_old" != "$PWD/data/dashboard" ] || [ "${DASHBOARD_DIR_IS_DEFAULT:-0}" -eq 0 ]; }; then
            if [ -n "$dashboard_data_dir_old" ] && [ -n "${DASHBOARD_DIR:-}" ] &&
                [ "$dashboard_data_dir_old" != "$DASHBOARD_DIR" ] && [ -f "$dashboard_data_dir_old/mining_data.db" ]; then
                # Arm recovery before carry_dashboard_data_move stops the dashboard. A later error
                # either removes the unpublished copy and retries the change, or keeps the committed
                # copy plus this marker so an unchanged re-apply still recreates the container.
                dashboard_carry_target=$(cd "$DASHBOARD_DIR" && pwd -P) || error "Could not resolve the new dashboard.data_dir ($DASHBOARD_DIR)."
                : >"$apply_marker"
                dashboard_carry_recovery=1
                trap 'recover_dashboard_data_carry "$dashboard_data_dir_old" "${DASHBOARD_DIR:-}" "$dashboard_carry_target" "$apply_marker" "$dashboard_carry_published" "$incomplete"; rm -f "${ENV_FILE}.new" "${ENV_FILE}.dryrun" 2>/dev/null || true' EXIT
            fi
            carry_dashboard_data_move "$dashboard_data_dir_old" "${DASHBOARD_DIR:-}"
            [ "$dashboard_carry_recovery" -eq 0 ] || dashboard_carry_published=1
        fi
        # Re-arm the sync gate with the restore's marker (#2626). Each key above reaches the
        # dashboard's environment (the port via MONERO_RPC_URL), so compose recreates it and it
        # reads the marker at start. It holds the miner until the new node syncs (or releases on the first cycle if it already has).
        # The directory belongs to the dashboard's uid (ensure_directories), hence sudo when the
        # operator's is another; the dashboard removes the file through its directory either way.
        if [ "$rearm_sync_gate" -eq 1 ] && ! { : >"$DASHBOARD_DIR/sync-gate-reset" 2>/dev/null ||
            sudo touch "$DASHBOARD_DIR/sync-gate-reset"; }; then
            error "Could not re-arm the sync gate ($DASHBOARD_DIR/sync-gate-reset)."
        fi
        mv "$newenv" "$ENV_FILE"
        provision_node_onions # #103: a node that just went local needs its onion before it starts
        inject_service_configs
        # Whether caddy needs a restart is decided by COMPARING the rendered file, never by a list
        # of keys someone has to remember to extend (#1052). The list had drifted:
        # dashboard.expose_public_ip was missing from it, so turning OFF the opt-in that serves the
        # dashboard on a globally-routable address re-rendered the Caddyfile without its bind lines
        # and left caddy holding the wildcard listener — the operator sees the setting saved, sees
        # the file change, and the box stays exposed.
        #
        # An absent previous file is a fresh install: compose starts caddy on the new one below, so
        # there is no old configuration to displace. Emptiness is not absence — a zero-byte file
        # left by a crashed render is a box whose caddy serves nothing, and that wants the restart.
        if [ -f "Caddyfile" ]; then
            caddy_had=1
            caddy_before=$(cat "Caddyfile")
        fi
        generate_caddyfile
        if [ "$caddy_had" -eq 1 ] && [ "$caddy_before" != "$(cat "Caddyfile" 2>/dev/null)" ]; then
            caddy_changed=1
        fi
    else
        rm -f "$newenv"
        if [ "$incomplete" -eq 0 ]; then
            # #33: converge the control-runner units BEFORE returning. A box whose units point at
            # a dead install has an unchanged config by definition — the fault is in the unit
            # files, not config.json — so returning here first made `apply` the one thing that
            # could not repair it, while doctor was telling the operator to run exactly that.
            # Idempotent and sudo-free when the units already match.
            mutation_lock_acquire apply
            provision_control_runner
            reconcile_appliance_hostname
            apply_refresh_appliance_tls # #1265: the mint doctor sends the operator here for
            log "No configuration changes detected. Nothing to apply."
            mutation_lock_release
            return 0
        fi
        warn "A previous apply updated the config but did not finish recreating containers — retrying."
    fi

    # The retry branch reaches here without a hold; the changed branch already has one.
    if [ "$lock_held" -eq 0 ]; then
        mutation_lock_acquire apply
        lock_held=1
    fi
    # Client-auth keys must be written before tor is recreated below, so an onion just turned on (or a
    # client-auth toggle) takes effect on this apply rather than the next (#343).
    provision_onion_client_auth
    provision_control_runner
    provision_ssh_access
    provision_console_login   # #33: converge the control-runner units on the (new) toggle
    render_local_miner_config # #796: the built-in miner's config is derived — keep it current

    log "Updating containers..."
    migrate_compose_project
    # (Re)assert the Tor-only egress firewall BEFORE compose recreates anything — same ordering as
    # up/upgrade (#276/#291), for the same reason: if it isn't already installed (e.g. `down` then
    # `apply`), recreating containers first opens a startup window where a clearnet app dials out
    # before the rules go in. Idempotent, so the common case
    # (already installed from `up`) is a cheap re-assert; the .env it reads was committed just above.
    apply_tor_egress_firewall
    # Mark the recreate in-flight: cleared only after a SUCCESSFUL `up`, so a failure here (image
    # build error, a port already bound, a failed health/dependency gate, daemon hiccup) leaves the
    # marker for the next apply to retry instead of no-opping on the already-committed config (#125).
    : >"$apply_marker"
    # One-time move of the dashboard data out of the install dir (#455) — after the confirmed
    # commit above (never before the operator said yes) and under the marker, so a failed move is
    # retried; the recreate below then mounts the migrated directory.
    migrate_dashboard_data
    # Compose recreates only the services whose resolved config changed. --remove-orphans covers
    # services that left the compose file entirely; a profile-deactivated service is NOT an orphan
    # to compose, so compose_up_checked removes those containers itself before the up (#795).
    if ! compose_up_checked -d --remove-orphans; then
        warn "Config files were updated but containers were NOT recreated ('docker compose up' failed)."
        warn "Fix the cause shown above, then re-run '$0 apply' (it will retry the recreate) — or '$0 up'."
        exit 1 # leave $apply_marker in place so the retry re-attempts the recreate
    fi
    if [ "$dashboard_carry_recovery" -eq 1 ]; then
        dashboard_carry_recovery=0
        trap 'rm -f "${ENV_FILE}.new" "${ENV_FILE}.dryrun" 2>/dev/null || true' EXIT
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
        fi
    fi
    rm -f "$apply_marker"
    # Converge the built-in miner on a toggle without waiting for a reboot (#796): start it when
    # local_miner just turned on, stop it when it turned off. After the recreate above so the
    # stratum the miner dials is the freshly-applied one. Best-effort, same posture as setup.
    provision_local_miner || true
    log "Configuration applied."
    announce_dashboard_url
    mutation_lock_release
}
