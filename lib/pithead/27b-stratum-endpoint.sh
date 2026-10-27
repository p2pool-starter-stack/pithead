parse_stratum_endpoint() {
    STRATUM_BIND=$(jq -r '.p2pool.stratum_bind // "0.0.0.0"' "$CONFIG_FILE")
    if ! is_ipv4 "$STRATUM_BIND"; then
        error "p2pool.stratum_bind must be an IPv4 address like \"0.0.0.0\", \"127.0.0.1\", or your LAN IP (got \"$STRATUM_BIND\")."
    fi

    STRATUM_PORT=$(jq -r '.p2pool.stratum_port // 3333' "$CONFIG_FILE")
    if ! printf '%s' "$STRATUM_PORT" | grep -qE '^[0-9]{1,5}$' || [ "$STRATUM_PORT" -lt 1 ] || [ "$STRATUM_PORT" -gt 65535 ]; then
        error "p2pool.stratum_port must be an integer between 1 and 65535 (got \"$STRATUM_PORT\")."
    fi
}
