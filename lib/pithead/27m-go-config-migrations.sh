_config_migration_binary() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    printf '%s' "$binary"
}

_config_workers_plan_go() {
    local binary conflict need populated native_rc extra
    binary=$(_config_migration_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' conflict && IFS= read -r -d '' need &&
            IFS= read -r -d '' populated && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%s\0%d\0' "$XVB_ALIAS_KEYS_JQ" "$XVB_ALIAS_V1_DEFAULTS_JQ" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-migrations "$binary" workers-plan 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$need:$populated" in true:true | true:false | false:false) ;; *) return 125 ;; esac
    _config_migration_conflict="$conflict"
    _config_migration_need="$need"
    _config_migration_populated="$populated"
}

_config_workers_write_go() {
    local binary rendered native_rc extra
    [ -n "$1" ] || return 125
    binary=$(_config_migration_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%s\0%d\0' "$XVB_ALIAS_KEYS_JQ" "$XVB_ALIAS_V1_DEFAULTS_JQ" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-migrations "$binary" workers-json 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ -n "$rendered" ] || return 125
    printf '%s' "$rendered" 2>/dev/null >"$1"
}

_config_telegram_plan_go() {
    local binary need enabled native_rc extra
    binary=$(_config_migration_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' need && IFS= read -r -d '' enabled &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-migrations "$binary" telegram-plan 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$need:$enabled" in true:true | true:false | false:false) ;; *) return 125 ;; esac
    _config_migration_need="$need"
    _config_migration_enabled="$enabled"
}

_config_telegram_write_go() {
    local binary rendered native_rc extra
    [ -n "$1" ] || return 125
    binary=$(_config_migration_binary) || return 125
    command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' rendered && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-migrations "$binary" telegram-json 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ -n "$rendered" ] || return 125
    printf '%s' "$rendered" 2>/dev/null >"$1"
}
