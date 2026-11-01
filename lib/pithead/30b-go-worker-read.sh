_config_worker_read_binary() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    printf '%s' "$binary"
}

_config_worker_read_project_go() {
    local source="$1" target="$2" binary rendered native_rc extra
    [ -n "$target" ] || return 125
    if [ "$source" -ef "$target" ]; then return 125; fi
    binary=$(_config_worker_read_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$source" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$source" 2>/dev/null || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-worker-read "$binary" project 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    printf '%s' "$rendered"
}

_config_worker_read_project() {
    _config_worker_read_project_go "$1" "$2" && return 0
    [ "$?" -eq 125 ] || return
    _config_worker_read_project_bash "$1"
}

_config_worker_read_values_go() {
    local row="$1" binary native_rc extra
    binary=$(_config_worker_read_binary) || return 125
    {
        IFS= read -r -d '' _config_worker_read_name &&
            IFS= read -r -d '' _config_worker_read_host &&
            IFS= read -r -d '' _config_worker_read_token &&
            IFS= read -r -d '' _config_worker_read_port &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local helper_rc=0
        printf '%s\0%d\0' "$row" 0 |
            PITHEAD_GO_HELPER=config-worker-read "$binary" values 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
}

_config_worker_read_values() {
    local rc
    if _config_worker_read_values_go "$1"; then
        _config_worker_read_values_fallback=0
        return 0
    else
        rc=$?
    fi
    [ "$rc" -eq 125 ] || return "$rc"
    _config_worker_read_values_fallback=1
    _config_worker_read_values_bash "$1"
}

_config_worker_read_record_go() {
    local name="$1" host="$2" port="$3" read="$4" target="$5"
    local binary rendered native_rc extra
    [ -n "$target" ] && [ "${_config_worker_read_values_fallback:-0}" = 0 ] || return 125
    binary=$(_config_worker_read_binary) || return 125
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local helper_rc=0
        printf '%s\0%s\0%s\0%s\0%d\0' "$name" "$host" "$port" "$read" 0 |
            PITHEAD_GO_HELPER=config-worker-read "$binary" record 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ -n "$rendered" ] || return 125
    printf '%s' "$rendered" >>"$target"
}

_config_worker_read_record() {
    _config_worker_read_record_go "$@" && return 0
    [ "$?" -eq 125 ] || return
    _config_worker_read_record_bash "$@"
}

_config_worker_read_slurp_go() {
    local source="$1" target="$2" binary rendered native_rc extra
    [ -n "$target" ] || return 125
    if [ "$source" -ef "$target" ]; then return 125; fi
    binary=$(_config_worker_read_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$source" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$source" 2>/dev/null || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-worker-read "$binary" slurp 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ -n "$rendered" ] || return 125
    printf '%s' "$rendered" >"$target"
}

_config_worker_read_slurp() {
    _config_worker_read_slurp_go "$1" "$2" && return 0
    [ "$?" -eq 125 ] || return
    _config_worker_read_slurp_bash "$1" "$2"
}
