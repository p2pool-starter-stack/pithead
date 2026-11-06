announce_dashboard_url() {
    local display_host pool_host bind
    display_host=$(env_get HOST_IP)
    [ -z "$display_host" ] && display_host="$(hostname)"
    if [ "$(env_get DASHBOARD_SECURE)" == "true" ]; then
        log "Dashboard available at: https://$display_host"
    else
        log "Dashboard available at: http://$display_host"
    fi
    bind=$(env_get STRATUM_BIND)
    case "$bind" in
    '' | 0.0.0.0) pool_host="$display_host" ;;
    *) pool_host="$bind" ;;
    esac
    log "Pool URL: $pool_host:$(stratum_port_effective)"
    [ "$bind" != "127.0.0.1" ] || log "Stratum is bound to loopback: local connections only."
    announce_stratum_auth
    announce_stratum_tls # #261: prints the fingerprint rigs pin; no-op when TLS is off
    announce_local_miner # #593: hand off the pool URL + secret for a co-located RigForge worker
}

announce_local_miner() {
    [ "$(config_get .local_miner.enabled 2>/dev/null || echo false)" = "true" ] || return 0
    if is_appliance; then
        if local_miner_hugepages_blocked; then
            warn "Local mining is opted in, but this machine's reduced HugePages reservation cannot also fit a co-located miner — the built-in RigForge worker is not started. Use a 16 GB machine for the built-in miner."
        else
            log "Local mining is ON: this machine also mines with its own CPU. The built-in RigForge worker points at the stack's own stratum and appears in the dashboard's Workers view."
        fi
        return 0
    fi
    local bind port host secret
    bind=$(env_get STRATUM_BIND 2>/dev/null || true)
    [ -n "$bind" ] || bind="0.0.0.0"
    port=$(stratum_port_effective)
    # A port published on all interfaces (0.0.0.0) or on loopback is reachable at 127.0.0.1; a
    # specific LAN bind (#593 edge case) is only reachable at that address, so target it directly
    # rather than hardcoding loopback.
    case "$bind" in
    0.0.0.0 | 127.0.0.1) host="127.0.0.1" ;;
    *) host="$bind" ;;
    esac
    secret=$(env_get PROXY_STRATUM_PASSWORD 2>/dev/null || true)
    log "Local miner opt-in is ON: point a RigForge install on THIS host at the stack's stratum:"
    log "  • Pool URL:         $host:$port"
    if [ -n "$secret" ]; then
        log "  • Stratum password: $secret"
    else
        log "  • Stratum password: none set (any password is accepted)"
    fi
    log "  RigForge compiles/tunes XMRig and owns all host tuning (HugePages/GRUB/MSR) — Pithead does not. See $DOCS_URL/docs/workers.md#mine-on-the-stack-host-itself."
}

# Surface the stratum access-password (#152) so the operator can configure each rig's 'pass'.
# The operator's shared secret already lives in .env; show it again so a later rig can connect.
announce_stratum_auth() {
    local sp
    sp=$(env_get PROXY_STRATUM_PASSWORD 2>/dev/null || true)
    if [ -z "$sp" ]; then
        log "Stratum password: none set (any password is accepted)"
        return 0
    fi
    log "Stratum password: $sp"
    log "Stratum authentication is ON: every rig must connect with pass \"$sp\" (set it as the xmrig/RigForge stratum password). See $DOCS_URL/docs/workers.md#authentication."
}
