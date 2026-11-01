_parse_wallet_settings_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" assigned monero tari reason native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' assigned && IFS= read -r -d '' monero &&
            IFS= read -r -d '' tari && IFS= read -r -d '' reason &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%s\0%d\0' "$TARI_MODE" "$CONFIG_FILE" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-wallet-settings "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$assigned" in
    0) [ -n "$reason" ] && [ -z "$monero" ] && [ -z "$tari" ] || return 125 ;;
    2) ;;
    *) return 125 ;;
    esac
    if [ "$assigned" = 2 ]; then
        MONERO_WALLET="$monero"
        TARI_WALLET="$tari"
    fi
    [ -z "$reason" ] || error "$reason"
    return 0
}
