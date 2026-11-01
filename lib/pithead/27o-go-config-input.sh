_parse_config_input_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" stage reason native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v python3 >/dev/null 2>&1 &&
        command -v jq >/dev/null 2>&1 && command -v cat >/dev/null 2>&1 || return 125
    [ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' stage && IFS= read -r -d '' reason &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-input-validation "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$stage:$reason" in
    ok:) return 0 ;;
    document:?*) error "Invalid configuration: $reason." ;;
    webhooks:?*) error "$reason" ;;
    controls:control-character)
        error "$CONFIG_FILE has a config value containing a control character or newline. That is not allowed — it could inject an extra line into the stack's .env. Remove the newline/control character (check secrets like node_password, bot_token, api_token)."
        ;;
    *) return 125 ;;
    esac
}
