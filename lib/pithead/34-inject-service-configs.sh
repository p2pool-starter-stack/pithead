inject_service_configs() {
    log "Injecting service configurations..."
    install_chain_runtime_config || return 1

    local _csdir _cdir
    _csdir=$(clearnet_state_dir)
    _cdir=$(env_get CONTROL_DIR 2>/dev/null)
    [ -n "$_cdir" ] || _cdir="$PWD/data/control"
    mkdir -p "$_csdir" 2>/dev/null || true
    [ "$(normalize_bool "$(config_bool '.monero.clearnet_initial_sync' false)")" = "true" ] ||
        sudo rm -f "$_csdir/monero.synced" "$_csdir/monero.synced.tor" "$_cdir/results/clearnet-monero-tor.json" "$_cdir/results/clearnet-monero-baseline.json" || return 1
    [ "$(normalize_bool "$(config_bool '.tari.clearnet_initial_sync' false)")" = "true" ] ||
        sudo rm -f "$_csdir/tari.synced" "$_csdir/tari.synced.tor" "$_cdir/results/clearnet-tari-tor.json" "$_cdir/results/clearnet-tari-baseline.json" || return 1
}
