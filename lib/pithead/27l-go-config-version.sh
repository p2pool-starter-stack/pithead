_config_version_binary() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    printf '%s' "$binary"
}

_config_version_scalar_go() {
    local operation="$1" value="$2" binary first second result native_rc extra
    binary=$(_config_version_binary) || return 125
    {
        IFS= read -r -d '' first || return 125
        if IFS= read -r -d '' second; then
            result="$first"
            native_rc="$second"
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; } || return 125
        else
            [ -z "$second" ] || return 125
            result=""
            native_rc="$first"
        fi
    } < <(
        local helper_rc=0
        PITHEAD_GO_HELPER=config-version "$binary" "$operation" "$value" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$native_rc" in 0 | 1 | 125) ;; *) return 125 ;; esac
    [ "$native_rc" = 0 ] || [ -z "$result" ] || return 125
    if [ "$operation" = normalize ]; then
        [ "$native_rc" != 0 ] || [ -n "$result" ] || return 125
    else
        [ -z "$result" ] || return 125
    fi
    if [ "$native_rc" = 0 ] && [ "$operation" = normalize ]; then printf '%s' "$result"; fi
    return "$native_rc"
}

_config_version_normalize_go() { _config_version_scalar_go normalize "$1"; }
_config_version_ok_go() { _config_version_scalar_go ok "$1"; }

_config_version_plan_go() {
    local binary stamp newer malformed equal native_rc extra
    binary=$(_config_version_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' stamp &&
            IFS= read -r -d '' newer &&
            IFS= read -r -d '' malformed &&
            IFS= read -r -d '' equal &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%d\0' "$1" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-version "$binary" plan 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$newer:$malformed:$equal" in
    true:true:* | true:*:true | *:true:true) return 125 ;;
    true:false:false | false:true:false | false:false:true | false:false:false) ;;
    *) return 125 ;;
    esac
    _config_version_stamp="$stamp"
    _config_version_newer="$newer"
    _config_version_malformed="$malformed"
    _config_version_equal="$equal"
    return 0
}

_config_version_write_go() {
    local binary rendered native_rc extra
    [ -n "$2" ] || return 125
    if [ "$CONFIG_FILE" -ef "$2" ]; then return 125; fi
    binary=$(_config_version_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%d\0' "$1" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-version "$binary" json 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ -n "$rendered" ] || return 125
    printf '%s' "$rendered" 2>/dev/null >"$2"
}
