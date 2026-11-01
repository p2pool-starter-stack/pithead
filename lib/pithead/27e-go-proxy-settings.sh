_parse_proxy_config_go() {
    local binary="${_pithead_go_hybrid_binary:-}" assigned password tls donation reason native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' assigned &&
            IFS= read -r -d '' password &&
            IFS= read -r -d '' tls &&
            IFS= read -r -d '' donation &&
            IFS= read -r -d '' reason &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local helper_rc=0
        PITHEAD_GO_HELPER=config-proxy-settings "$binary" "$CONFIG_FILE" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$assigned" in
    1) [ -n "$reason" ] || return 125 ;;
    3) ;;
    *) return 125 ;;
    esac
    STRATUM_PASSWORD="$password"
    if [ "$assigned" = 3 ]; then
        STRATUM_TLS="$tls"
        DONATE_LEVEL="$donation"
    fi
    [ -z "$reason" ] || error "$reason"
    return 0
}
