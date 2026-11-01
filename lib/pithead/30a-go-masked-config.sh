_config_masked_binary() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    printf '%s' "$binary"
}

_config_masked_write_go() {
    local source="$1" target="$2" binary rendered native_rc extra
    [ -n "$target" ] || return 125
    if [ "$source" -ef "$target" ]; then return 125; fi
    binary=$(_config_masked_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$source" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$source" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%d\0' "$CONTROL_SECRET_PATHS" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-masked "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ -n "$rendered" ] || return 125
    printf '%s' "$rendered" 2>/dev/null >"$target"
}
