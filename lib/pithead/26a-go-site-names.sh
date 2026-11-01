_appliance_site_names_go() {
    local base="$1" bridges="$2" prefix="$3" expose="$4" binary="${_pithead_go_hybrid_binary:-}"
    local candidate native_names native_rc extra producer_rc helper_rc
    shift 4
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' native_names &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        producer_rc=0
        helper_rc=0
        {
            printf '%s\0%s\0%s\0%s\0%d\0' "$base" "$bridges" "$prefix" "$expose" "$#" || producer_rc=$?
            for candidate in "$@"; do printf '%s\0' "$candidate" || producer_rc=$?; done
            printf '%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-site-names "$binary" expand 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    names="$native_names"
}

_appliance_cert_alt_string_go() {
    local binary="${_pithead_go_hybrid_binary:-}" h native_out native_rc extra producer_rc helper_rc
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' native_out &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        producer_rc=0
        helper_rc=0
        {
            printf '%d\0' "$#" || producer_rc=$?
            for h in "$@"; do printf '%s\0' "$h" || producer_rc=$?; done
            printf '%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-site-names "$binary" san 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    out="$native_out"
}
