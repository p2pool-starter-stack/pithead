_config_persistence_binary() {
    local binary="${_pithead_go_hybrid_binary:-}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    printf '%s' "$binary"
}

_config_credentials_write_go() {
    local config="$1" user="$2" pass="$3" target="$4"
    local binary rendered native_rc extra
    [ -n "$target" ] || return 125
    if [ "$config" -ef "$target" ]; then return 125; fi
    binary=$(_config_persistence_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$config" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$config" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%s\0%d\0' "$user" "$pass" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-persistence "$binary" credentials 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ -n "$rendered" ] || return 125
    printf '%s' "$rendered" 2>/dev/null >"$target"
}

_config_appliance_write_go() {
    local config="$1" defaults="$2" target="$3"
    local binary rendered native_rc extra
    [ -n "$target" ] || return 125
    if [ "$config" -ef "$target" ]; then return 125; fi
    binary=$(_config_persistence_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$config" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$config" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%d\0' "$defaults" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-persistence "$binary" appliance 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ -n "$rendered" ] || return 125
    printf '%s' "$rendered" 2>/dev/null >"$target"
}

_config_credentials_publish_commands() {
    local command path
    [ "$(type -t umask)" = builtin ] || return 125
    for command in cat mv chmod rm; do
        [ "$(type -t "$command")" = file ] || return 125
        path=$(type -P "$command") || return 125
        case "$path" in
        "/usr/bin/$command" | "/bin/$command") ;;
        *) return 125 ;;
        esac
    done
}

_config_credentials_publish_go() {
    [ "$#" -eq 3 ] || return 125
    local config="$1" user="$2" pass="$3" stage="${1}.tmp"
    local binary native_rc extra
    case "$config" in -*) return 125 ;; esac
    [ ! -e "$stage" ] && [ ! -L "$stage" ] || return 125
    _config_credentials_publish_commands || return 125
    binary=$(_config_persistence_binary) || return 125
    {
        IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$config" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%s\0%s\0%d\0' "$config" "$user" "$pass" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-persistence "$binary" credentials publish 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
}
