_caddy_auth_go() {
    local operation="$1" binary="${_pithead_go_hybrid_binary:-}" candidate native_rc native_extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    [ "$operation" != auth ] || [ -z "${DASHBOARD_AUTH_HASH_B64:-}" ] || [ "${DASHBOARD_AUTH_USER+x}" = x ] || return 125
    {
        IFS= read -r -d '' candidate &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' native_extra && [ -z "$native_extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            case "$operation" in
            auth)
                printf '%s\0' "${DASHBOARD_AUTH_USER:-}" "${DASHBOARD_AUTH_HASH_B64:-}" || producer_rc=$?
                ;;
            boot)
                printf '%s\0' "${DASHBOARD_AUTH_HASH_B64:-}" || producer_rc=$?
                ;;
            *) return 125 ;;
            esac
            printf '%d\0' "$producer_rc"
        } |
            PITHEAD_GO_HELPER=config-caddy-auth "$binary" "$operation" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    printf '%s' "$candidate"
}
