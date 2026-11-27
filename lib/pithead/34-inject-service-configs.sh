inject_service_configs() {
    log "Injecting service configurations..."
    local tari_onion_short="${TARI_ONION%%.*}" tari_tmp
    if tari_tmp=$(mktemp -d build/.tari-render.XXXXXX); then
        cp -P -- build/tari/config.toml.template "$tari_tmp/config.toml" && [ ! -L "$tari_tmp/config.toml" ] &&
            chmod 644 "$tari_tmp/config.toml" &&
            safe_sed "s/<your_tari_onion_address_no_extension>/$tari_onion_short/g" "$tari_tmp/config.toml" &&
            safe_sed "s/172\.28\.0/$NETWORK_PREFIX/g" "$tari_tmp/config.toml" &&
            mv -fT -- "$tari_tmp/config.toml" build/tari/config.toml ||
            warn "Could not render build/tari/config.toml from its template; the file was left as it was."
        rm -f "$tari_tmp/config.toml"
        rmdir "$tari_tmp" 2>/dev/null || true
    else
        warn "Could not create a render folder in build/; build/tari/config.toml was left as it was."
    fi

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
