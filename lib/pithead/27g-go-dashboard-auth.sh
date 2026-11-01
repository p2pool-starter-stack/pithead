_parse_dashboard_auth_go() {
    local binary="${_pithead_go_hybrid_binary:-}" user password reason native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' user &&
            IFS= read -r -d '' password &&
            IFS= read -r -d '' reason &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-dashboard-auth "$binary" settings 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    DASHBOARD_AUTH_USER="$user"
    DASHBOARD_AUTH_HASH_B64=""
    DASHBOARD_AUTH_PW_FP=""
    dash_pw="$password"
    [ -z "$reason" ] || error "$reason"
    return 0
}

_parse_dashboard_policy_go() {
    local binary="${_pithead_go_hybrid_binary:-}" assigned onion client control reason native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' assigned &&
            IFS= read -r -d '' onion &&
            IFS= read -r -d '' client &&
            IFS= read -r -d '' control &&
            IFS= read -r -d '' reason &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%s\0%d\0' "$dash_pw" "$0" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-dashboard-auth "$binary" policy 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$assigned" in
    2) [ -n "$reason" ] || return 125 ;;
    3) ;;
    *) return 125 ;;
    esac
    DASHBOARD_ONION_ENABLED="$onion"
    DASHBOARD_ONION_CLIENT_AUTH="$client"
    if [ "$assigned" = 3 ]; then DASHBOARD_CONTROL_ENABLED="$control"; fi
    [ -z "$reason" ] || error "$reason"
    return 0
}
