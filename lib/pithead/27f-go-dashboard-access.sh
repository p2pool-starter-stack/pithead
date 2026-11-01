_parse_dashboard_access_go() {
    local binary="${_pithead_go_hybrid_binary:-}" platform assigned host port secure expose timezone needs_host reason native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    platform=$(config_platform 2>/dev/null) || return 125
    {
        IFS= read -r -d '' assigned &&
            IFS= read -r -d '' host &&
            IFS= read -r -d '' port &&
            IFS= read -r -d '' secure &&
            IFS= read -r -d '' expose &&
            IFS= read -r -d '' timezone &&
            IFS= read -r -d '' needs_host &&
            IFS= read -r -d '' reason &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0' "$platform" || producer_rc=$?
            config_defaults_json 2>/dev/null || producer_rc=$?
            printf '\0' || producer_rc=$?
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-dashboard-access "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$assigned:$needs_host" in
    1:false | 2:false) [ -n "$reason" ] || return 125 ;;
    5:true) [ -z "$reason" ] && [ -z "$timezone" ] || return 125 ;;
    5:false) [ -z "$reason" ] && [ -n "$timezone" ] || return 125 ;;
    *) return 125 ;;
    esac
    DASHBOARD_HOST="$host"
    if [ "$assigned" != 1 ]; then HOST_PORT="$port"; fi
    [ -z "$reason" ] || error "$reason"
    DASHBOARD_SECURE="$secure"
    DASHBOARD_EXPOSE_PUBLIC_IP="$expose"
    dashboard_access_timezone="$timezone"
    return 0
}
