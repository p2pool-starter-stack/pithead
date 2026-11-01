_parse_directories_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" native_rc extra index
    local -a values=() names=(
        MONERO_DIR TARI_DIR P2POOL_DIR TOR_DATA_DIR DASHBOARD_DIR DASHBOARD_DIR_IS_DEFAULT
        PROXY_TLS_DIR CLEARNET_STATE_DIR CONTROL_DIR CADDY_LOG_DIR _data_root _dash_cfg
    )
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        for ((index = 0; index < 12; index++)); do
            IFS= read -r -d '' "values[index]" || return 125
        done
        IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0' "$PWD" || producer_rc=$?
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-directories "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "${values[5]}" in 0 | 1) ;; *) return 125 ;; esac
    for ((index = 0; index < 12; index++)); do
        printf -v "${names[index]}" '%s' "${values[index]}"
    done
    return 0
}
