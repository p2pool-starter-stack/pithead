parse_stratum_endpoint() {
    # Host interface the stratum port (:3333) publishes on. Default 0.0.0.0 so LAN rigs can
    # reach it out of the box; narrow it (e.g. a specific LAN IP, or 127.0.0.1 to disable LAN
    # access) on a public-IP host. Validate it's an IPv4 literal so a typo can't produce an
    # unparseable compose port binding. Rendered to STRATUM_BIND in .env.
    STRATUM_BIND=$(jq -r '.p2pool.stratum_bind // "0.0.0.0"' "$CONFIG_FILE")
    if ! is_ipv4 "$STRATUM_BIND"; then
        error "p2pool.stratum_bind must be an IPv4 address like \"0.0.0.0\", \"127.0.0.1\", or your LAN IP (got \"$STRATUM_BIND\")."
    fi

    # Operator-facing stratum port (#172), default 3333 — the host port xmrig-proxy binds and
    # publishes, i.e. what every rig dials. Rendered to STRATUM_PORT in .env; RigForge rigs must
    # point at the same port (rigforge pool.port). p2pool's container-INTERNAL stratum stays fixed
    # at :3333 (only xmrig-proxy dials it on the bridge), so P2POOL_URL is untouched by this knob.
    STRATUM_PORT=$(jq -r '.p2pool.stratum_port // 3333' "$CONFIG_FILE")
    if ! printf '%s' "$STRATUM_PORT" | grep -qE '^[0-9]{1,5}$' || [ "$STRATUM_PORT" -lt 1 ] || [ "$STRATUM_PORT" -gt 65535 ]; then
        error "p2pool.stratum_port must be an integer between 1 and 65535 (got \"$STRATUM_PORT\")."
    fi
}
