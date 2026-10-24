setup() {
    if is_deployed; then
        warn "A previous deployment was detected."
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

    setup_confirmed
}

setup_confirmed() {
    mutation_lock_acquire setup

    check_prerequisites
    ensure_config_exists
    ensure_onion_password
    PITHEAD_CONFIG_SET=1 parse_and_validate_config
    preflight_resources
    check_stratum_exposure setup
    load_preserved_state
    resolve_dashboard_host "interactive"
    reconcile_appliance_hostname
    prepare_directories
    render_env
    provision_tor
    DEPLOYMENT_COMPLETED=true
    render_env
    inject_service_configs
    optimize_kernel
    generate_caddyfile
    provision_control_runner
    provision_egress_check_units
    provision_lan_guard_check_units
    render_local_miner_config
    update_current_symlink

    log "Deployment preparation complete!"
    mutation_lock_release
    announce_dashboard_url
    if [ "$REBOOT_REQUIRED" = true ]; then
        echo -e "\n${C_YELLOW}[!] ATTENTION: System optimization requires a reboot.${C_RESET}"
        echo "Please run: 'sudo reboot' now."
        echo "After reboot, start the stack with: '$0 up'"
    else
        prompt_start_stack
        provision_local_miner || true
    fi
}
