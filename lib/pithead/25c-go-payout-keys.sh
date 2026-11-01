_payout_public_view_key_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" verdict derived native_rc extra
    [ "$#" -ge 2 ] && command -v python3 >/dev/null 2>&1 || return 125
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' verdict && IFS= read -r -d '' derived &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0%s\0' "$1" "$2" || producer_rc=$?
            printf '%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-payout-keys "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$verdict:$derived" in
    1:) return 1 ;;
    0:*)
        [ "${#derived}" -eq 64 ] || return 125
        case "$derived" in *[!0-9a-f]*) return 125 ;; esac
        printf '%s\n' "$derived"
        ;;
    *) return 125 ;;
    esac
}
