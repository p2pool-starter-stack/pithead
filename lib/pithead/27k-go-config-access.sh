_parse_config_access_ssh_go() {
    local binary="${_pithead_go_hybrid_binary:-}" reason native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' reason &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%s\0%s\0%d\0' "$_ssh_release" "${PITHEAD_CONFIG_SET:-0}" "${PITHEAD_CONFIG_CARRIED_SSH:-0}" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-access-settings "$binary" ssh 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ -z "$reason" ] || error "$reason"
    return 0
}

_parse_config_access_node_go() {
    local binary="${_pithead_go_hybrid_binary:-}" user pass generate_user generate_pass native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' user && IFS= read -r -d '' pass &&
            IFS= read -r -d '' generate_user && IFS= read -r -d '' generate_pass &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%s\0%d\0' "$MONERO_MODE" "$MONERO_USER" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-access-settings "$binary" node 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$generate_user:$generate_pass" in
    true:true | true:false | false:true | false:false) ;;
    *) return 125 ;;
    esac
    MONERO_USER="$user"
    MONERO_PASS="$pass"
    _node_generate_user="$generate_user"
    _node_generate_pass="$generate_pass"
    return 0
}
