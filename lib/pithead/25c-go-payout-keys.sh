_payout_public_view_key_go() {
    local binary="${_pithead_go_hybrid_binary:-}" verdict derived native_rc extra
    [ "$#" -ge 2 ] && command -v python3 >/dev/null 2>&1 || return 125
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
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

_validate_payout_ownership_go() {
    local binary="${_pithead_go_hybrid_binary:-}" assigned spend reason native_rc extra
    local chain address_keys private_view explicit_spend docs_url
    local cannot_validate mismatch single decode spend_mismatch
    [ "$#" -eq 5 ] || return 125
    chain="$1"
    address_keys="$2"
    private_view="$3"
    explicit_spend="$4"
    docs_url="$5"
    command -v python3 >/dev/null 2>&1 || return 125
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' assigned && IFS= read -r -d '' spend &&
            IFS= read -r -d '' reason && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0%s\0%s\0%s\0%s\0' "$chain" "$address_keys" "$private_view" "$explicit_spend" "$docs_url" || producer_rc=$?
            printf '%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-payout-ownership "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    spend_mismatch='tari.spend_public_key disagrees with tari.wallet_address. Leave it empty to derive the public spend key from the address.'
    case "$chain" in
    monero)
        cannot_validate='Cannot validate monero.view_key: python3 must be available and the key must be a nonzero canonical private scalar.'
        mismatch="monero.view_key does not belong to monero.wallet_address: the public view key differs. Use the secret (not public) view key of the wallet that owns this address; see $docs_url/docs/dashboard.md#getting-your-view-keys."
        [ "$assigned" = 0 ] && [ -z "$spend" ] || return 125
        [ -z "$reason" ] || [ "$reason" = "$cannot_validate" ] || [ "$reason" = "$mismatch" ] || return 125
        ;;
    tari)
        cannot_validate='Cannot validate tari.view_key: python3 must be available and the key must be a nonzero canonical private scalar.'
        mismatch="tari.view_key does not belong to tari.wallet_address: the public view key differs. Use the private view key of the wallet that owns this address; see $docs_url/docs/dashboard.md#getting-your-view-keys."
        single='Tari payout confirmation needs a dual-key address, which Tari Universe gives by default. A single-key address carries no public view key to check tari.view_key against. Mining payouts to single-key addresses remain supported.'
        decode='Cannot decode tari.wallet_address for payout confirmation; python3 must be available.'
        if [ "$assigned" = 1 ]; then
            [ "${#spend}" -eq 64 ] || return 125
            case "$spend" in *[!0-9a-f]*) return 125 ;; esac
            [ -z "$reason" ] || [ "$reason" = "$spend_mismatch" ] || return 125
        elif [ "$assigned" = 0 ] && [ -z "$spend" ]; then
            [ "$reason" = "$cannot_validate" ] || [ "$reason" = "$mismatch" ] ||
                [ "$reason" = "$single" ] || [ "$reason" = "$decode" ] || return 125
        else
            return 125
        fi
        ;;
    *) return 125 ;;
    esac
    [ "$assigned" = 0 ] || TARI_SPEND_PUBLIC_KEY="$spend"
    [ -z "$reason" ] || error "$reason"
}
