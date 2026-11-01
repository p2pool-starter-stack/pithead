_config_env_read_binary() {
    local binary="${_pithead_go_hybrid_binary:-}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    printf '%s' "$binary"
}

_config_env_read_result() {
    local rendered="$1" reason="$2"
    [ -z "$reason" ] || error "$reason"
    printf '%s' "$rendered"
}

_dotenv_decode_value_go() {
    local value="$1" key="${2:-}" binary rendered reason native_rc helper_rc extra
    binary=$(_config_env_read_binary) || return 125
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' reason && IFS= read -r -d '' native_rc &&
            IFS= read -r -d '' helper_rc && [ "$native_rc" = 0 ] && [ "$helper_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local helper_rc=0
        printf '%s\0%s\0%d\0' "$value" "$key" 0 |
            PITHEAD_GO_HELPER=config-env-read "$binary" decode 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    _config_env_read_result "$rendered" "$reason"
}

_env_get_file_go() {
    local file="$1" key="$2" binary rendered reason native_rc helper_rc extra
    [ -f "$file" ] || return 0
    case "$file" in -*) return 125 ;; esac
    binary=$(_config_env_read_binary) || return 125
    command -v cat >/dev/null 2>&1 && command -v grep >/dev/null 2>&1 || return 125
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' reason && IFS= read -r -d '' native_rc &&
            IFS= read -r -d '' helper_rc && [ "$native_rc" = 0 ] && [ "$helper_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$file" 2>/dev/null || producer_rc=$?
            printf '\0%d\0%s\0' "$producer_rc" "$key"
        } | PITHEAD_GO_HELPER=config-env-read "$binary" get 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    _config_env_read_result "$rendered" "$reason"
}
