parse_stratum_endpoint() {
    if _parse_stratum_endpoint_go; then return 0; fi
    STRATUM_BIND=$(jq -r '.p2pool.stratum_bind // "0.0.0.0"' "$CONFIG_FILE")
    if ! is_ipv4 "$STRATUM_BIND"; then
        error "p2pool.stratum_bind must be an IPv4 address like \"0.0.0.0\", \"127.0.0.1\", or your LAN IP (got \"$STRATUM_BIND\")."
    fi

    STRATUM_PORT=$(jq -r '.p2pool.stratum_port // 3333' "$CONFIG_FILE")
    if ! printf '%s' "$STRATUM_PORT" | grep -qE '^[0-9]{1,5}$' || [ "$STRATUM_PORT" -lt 1 ] || [ "$STRATUM_PORT" -gt 65535 ]; then
        error "p2pool.stratum_port must be an integer between 1 and 65535 (got \"$STRATUM_PORT\")."
    fi
}

_parse_stratum_endpoint_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" stage bind port reason native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' stage &&
            IFS= read -r -d '' bind &&
            IFS= read -r -d '' port &&
            IFS= read -r -d '' reason &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local helper_rc=0
        PITHEAD_GO_HELPER=config-stratum "$binary" "$CONFIG_FILE" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$stage" in
    ok) [ -n "$bind" ] && [ -n "$port" ] && [ -z "$reason" ] || return 125 ;;
    bind-error) [ -z "$port" ] && [ -n "$reason" ] || return 125 ;;
    port-error) [ -n "$bind" ] && [ -n "$reason" ] || return 125 ;;
    *) return 125 ;;
    esac
    STRATUM_BIND="$bind"
    if [ "$stage" != bind-error ]; then STRATUM_PORT="$port"; fi
    [ -z "$reason" ] || error "$reason"
    return 0
}
