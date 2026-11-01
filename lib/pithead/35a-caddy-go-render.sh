_caddy_render_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    printf '%s\0' "$DASHBOARD_SECURE" "${HOST_PORT:-}" "$HOST_IP" \
        "$(_site_addresses http)" "$(_site_addresses https)" "$bind_addrs" "$auth" \
        "${tls_line:-}" "${boot_capability:-}" "${NETWORK_PREFIX:-}" "${DASHBOARD_ONION:-}" |
        PITHEAD_GO_HELPER=config-caddy "$binary" "$1"
}
