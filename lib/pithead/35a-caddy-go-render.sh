_caddy_render_go() {
    local binary="${_pithead_go_hybrid_binary:-}" site host_count=0 index producer_rc=0
    local -a site_tokens=()
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    for site in $site_hosts; do
        site_tokens[host_count]="$site"
        host_count=$((host_count + 1))
    done
    {
        printf '%s\0' "$DASHBOARD_SECURE" "${HOST_PORT:-}" "$HOST_IP" "$host_count" || producer_rc=$?
        for ((index = 0; index < host_count; index++)); do
            printf '%s\0' "${site_tokens[index]}" || producer_rc=$?
        done
        printf '%s\0' "$bind_addrs" "$auth" "${tls_line:-}" "${boot_capability:-}" \
            "${NETWORK_PREFIX:-}" "${DASHBOARD_ONION:-}" || producer_rc=$?
        printf '%s\0' "$producer_rc"
    } | PITHEAD_GO_HELPER=config-caddy "$binary" "$1" sites-v1
}
