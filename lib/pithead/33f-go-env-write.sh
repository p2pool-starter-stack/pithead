_write_env_go() {
    local path="$1" body="$2" binary="${_pithead_go_hybrid_binary:-}"
    local cat_path native_rc extra
    [ "$(type -t cat)" = file ] || return 125
    cat_path=$(type -P cat) || return 125
    case "$cat_path" in /bin/cat | /usr/bin/cat) ;; *) return 125 ;; esac
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0%s\0' "$path" "$body" || producer_rc=$?
            printf '%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-env-write "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
}
