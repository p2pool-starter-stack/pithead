_tari_secret_native_commands() {
    local command path
    for command in mktemp find chown mv rm; do
        [ "$(type -t "$command")" = file ] || return 125
        path=$(type -P "$command") || return 125
        case "$path" in
        "/usr/bin/$command" | "/bin/$command" | /usr/sbin/chown) ;;
        *) return 125 ;;
        esac
    done
}

_render_tari_secret_go() {
    local path="$1" uid="$2" gid="$3" view="$4" spend="$5" password="$6"
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" native_rc extra
    _tari_secret_native_commands || return 125
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0%s\0%s\0%s\0%s\0%s\0' "$path" "$uid" "$gid" "$view" "$spend" "$password" || producer_rc=$?
            printf '%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-tari-secret "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
}
