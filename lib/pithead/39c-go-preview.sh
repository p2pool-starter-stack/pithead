_config_preview_binary() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    printf '%s' "$binary"
}

_preview_describe_change_go() {
    local key="$1" old="$2" new="$3" binary rendered native_rc extra
    binary=$(_config_preview_binary) || return 125
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local helper_rc=0
        printf '%s\0%s\0%s\0%s\0%d\0' "$key" "$old" "$new" "${TARI_MODE:-}" 0 |
            PITHEAD_GO_HELPER=config-preview "$binary" describe 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    printf '%s' "$rendered"
}

_env_changed_keys_go() {
    local first="$1" second="$2" binary rendered native_rc extra locale_name locale_value
    [ -f "$first" ] && [ -f "$second" ] || return 125
    case "$first" in -*) return 125 ;; esac
    case "$second" in -*) return 125 ;; esac
    if [ -n "${LC_ALL:-}" ]; then
        case "$LC_ALL" in C | POSIX) ;; *) return 125 ;; esac
    else
        for locale_name in LC_COLLATE LC_CTYPE LANG; do
            locale_value=${!locale_name:-}
            case "$locale_value" in "" | C | POSIX) ;; *) return 125 ;; esac
        done
    fi
    binary=$(_config_preview_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local first_rc=0 second_rc=0 helper_rc=0
        {
            cat "$first" 2>/dev/null || first_rc=$?
            printf '\0%d\0' "$first_rc"
            cat "$second" 2>/dev/null || second_rc=$?
            printf '\0%d\0' "$second_rc"
        } | PITHEAD_GO_HELPER=config-preview "$binary" env-diff 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    printf '%s' "$rendered"
}
