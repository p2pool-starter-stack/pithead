inject_service_configs() {
    log "Injecting service configurations..."
    cp build/tari/config.toml.template build/tari/config.toml
    local tari_onion_short="${TARI_ONION%%.*}"
    safe_sed "s/<your_tari_onion_address_no_extension>/$tari_onion_short/g" build/tari/config.toml
    # Rebase the Tor SOCKS IP onto the configured subnet prefix (#180): a no-op at the
    # default 172.28.0, rewrites the .25 Tor IP when network.subnet has been moved.
    safe_sed "s/172\.28\.0/$NETWORK_PREFIX/g" build/tari/config.toml

    # config.toml is always rendered for Tor (onion, socks5 transport through Tor) — the CANONICAL
    # config. The optional clearnet initial sync (#183) is applied per-start inside the container by
    # build/tari/entrypoint.sh (which copies this file and transforms the copy), gated on the
    # TARI_CLEARNET_SYNC flag AND the dashboard's auto-transition marker (#234) — so once synced the
    # node returns to Tor on its own and `apply` never re-renders clearnet over it. Same idea for
    # monerod, whose entrypoint envsubsts + transforms in-container. Here we only re-arm:

    # Re-arm clearnet auto-sync (#234): clear a chain's "sync complete" marker whenever its flag is
    # OFF, so re-enabling later starts a fresh clearnet sync. While a flag is ON, leave the marker
    # and its host-owned attestation in place. A firewall toggle must not re-arm a completed sync.
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
