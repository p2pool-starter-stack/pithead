_caddy_bind_go() {
    local bridge_addrs="$1" prefix="$2" binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    local candidate native_rc native_extra producer_rc helper_rc
    shift 2
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' candidate &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' native_extra && [ -z "$native_extra" ]; }
    } < <(
        producer_rc=0
        helper_rc=0
        {
            printf '%s\0%s\0%d\0' "$bridge_addrs" "$prefix" "$#" || producer_rc=$?
            for native_extra in "$@"; do
                printf '%s\0' "$native_extra" || producer_rc=$?
            done
            printf '%d\0' "$producer_rc"
        } |
            PITHEAD_GO_HELPER=config-caddy-bind "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$candidate" in
    "127.0.0.1 ::1" | *" 127.0.0.1 ::1") ;;
    *) return 125 ;;
    esac
    printf '%s' "$candidate"
}
