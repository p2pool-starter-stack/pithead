_parse_payout_monero_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" assigned mode view_key scan_height enabled reason native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' assigned && IFS= read -r -d '' mode &&
            IFS= read -r -d '' view_key && IFS= read -r -d '' scan_height &&
            IFS= read -r -d '' enabled && IFS= read -r -d '' reason &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%d\0' "$DOCS_URL" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-payout-settings "$binary" monero 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$assigned:$enabled" in
    1:) [ -n "$reason" ] || return 125 ;;
    4:false) ;;
    4:true) [ -z "$reason" ] || return 125 ;;
    *) return 125 ;;
    esac
    MONERO_MODE="$mode"
    if [ "$assigned" = 4 ]; then
        MONERO_VIEW_KEY="$view_key" PAYOUT_SCAN_HEIGHT="$scan_height" PAYOUT_CONFIRM_ENABLED="$enabled"
    fi
    [ -z "$reason" ] || error "$reason"
    return 0
}

_parse_payout_tari_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" view_key spend_key birthday enabled reason native_rc extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    case "$CONFIG_FILE" in -*) return 125 ;; esac
    {
        IFS= read -r -d '' view_key && IFS= read -r -d '' spend_key &&
            IFS= read -r -d '' birthday && IFS= read -r -d '' enabled &&
            IFS= read -r -d '' reason && IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            cat "$CONFIG_FILE" 2>/dev/null || producer_rc=$?
            printf '\0%s\0%s\0%d\0' "$TARI_MODE" "$DOCS_URL" "$producer_rc"
        } | PITHEAD_GO_HELPER=config-payout-settings "$binary" tari 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ "$enabled" = false ] || return 125
    TARI_VIEW_KEY="$view_key" TARI_SPEND_PUBLIC_KEY="$spend_key"
    TARI_WALLET_BIRTHDAY="$birthday" TARI_PAYOUT_CONFIRM_ENABLED=false
    [ -z "$reason" ] || error "$reason"
    return 0
}

_validate_payout_birthday_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" reason native_rc extra helper_rc=0
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' reason && IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        printf '%s\0%s\0%d\0' "$TARI_WALLET_BIRTHDAY" "$tari_today" 0 |
            PITHEAD_GO_HELPER=config-payout-settings "$binary" birthday 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    _payout_birthday_reason="$reason"
    return 0
}
