# --- Top-level Commands ---

setup() {
    if is_deployed; then
        warn "A previous deployment was detected."
        # An interactive ask with no terminal is an EOF, and `read`'s `|| true` used to swallow
        # that into an empty answer — read as decline, exit 0: a headless caller believed setup
        # succeeded while nothing ran (#924's silent false success). Headless now REFUSES loudly
        # instead of proceeding: an unattended re-provision (Tor container recreate, full
        # re-render, a possible GRUB edit) must never ride on the mere absence of a terminal —
        # `pithead setup` has long been a safe probe on a deployed box for cron/automation, and
        # the appliance's own headless paths never reach this branch (a failed provisioning
        # attempt is not deployed). A real terminal keeps the prompt exactly as before.
        if [ -t 0 ]; then
            local RERUN
            read -r -p "Re-run setup (re-provisions Tor and may modify GRUB)? (y/N): " RERUN || true
            if [[ ! "$RERUN" =~ ^[Yy] ]]; then
                log "Setup skipped. Edit config.json and run '$0 apply' to propagate config changes,"
                log "or '$0 up' to start the stack."
                exit 0
            fi
        else
            error "Already provisioned, and re-running setup re-provisions Tor and may modify GRUB — run '$0 setup' from a terminal to confirm that. For configuration changes use '$0 apply'; to start the stack use '$0 up'."
        fi
    fi

    # After the re-run prompt above, so the hold never spans a human wait. The firstboot
    # wizard runs `(setup)` in a subshell (#1059), so this IS the wizard's hold and it is not one
    # line wider than the provisioning itself — the loop's wait for a submitted form is outside it.
    mutation_lock_acquire setup

    check_prerequisites
    ensure_config_exists
    ensure_onion_password
    PITHEAD_CONFIG_SET=1 parse_and_validate_config
    preflight_resources
    check_stratum_exposure setup
    load_preserved_state
    resolve_dashboard_host
    reconcile_appliance_hostname
    prepare_directories
    render_env
    provision_tor
    DEPLOYMENT_COMPLETED=true
    render_env
    inject_service_configs
    optimize_kernel
    generate_caddyfile
    provision_console_login
    provision_control_runner
    provision_egress_check_units
    provision_lan_guard_check_units
    render_local_miner_config
    update_current_symlink

    log "Deployment preparation complete!"
    mutation_lock_release
    announce_dashboard_url
    [ -z "${IN_DASH_PASS:-}" ] || wizard_print_pointer
    if [ "$REBOOT_REQUIRED" = true ]; then
        echo -e "\n${C_YELLOW}[!] ATTENTION: System optimization requires a reboot.${C_RESET}"
        echo "Please run: 'sudo reboot' now."
        echo "After reboot, start the stack with: '$0 up'"
    else
        prompt_start_stack
        # The miner leg comes AFTER the stack: it points at the stack's own stratum, and
        # RigForge starts the service it installs. Appliance-only inside; best-effort — a
        # miner that cannot start must not fail provisioning of the stack that just did.
        provision_local_miner || true
    fi
}
