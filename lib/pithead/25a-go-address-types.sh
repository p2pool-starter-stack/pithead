_config_address_type_go() {
    local chain address binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    local probe verdict native_rc extra
    [ "$#" -eq 2 ] || return 125
    chain="$1"
    address="$2"
    case "$chain" in
    monero) [ "${MONERO_ADDRESS_KEY_ONLY:-}" != 1 ] || return 125 ;;
    tari) [ "${TARI_ADDRESS_KEY_ONLY:-}" != 1 ] || return 125 ;;
    *) return 125 ;;
    esac
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v python3 >/dev/null 2>&1 || return 125
    probe=$(python3 -c 'print("ready")' 2>/dev/null && printf '.') && [ "$probe" = $'ready\n.' ] || return 125
    {
        IFS= read -r -d '' verdict && IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0%s\0' "$chain" "$address" || producer_rc=$?
            printf '%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-address "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$chain:$verdict" in
    monero:primary | monero:integrated | monero:subaddress | monero:checksum | monero:invalid) ;;
    tari:ok | tari:checksum | tari:network | tari:invalid) ;;
    *) return 125 ;;
    esac
    printf '%s\n' "$verdict"
}
