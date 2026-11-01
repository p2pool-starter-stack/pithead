_parse_lifecycle_options_go() {
    local verb="$1" binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    local kind argument native_yes native_dry_run native_porcelain native_rc extra
    shift
    case "$verb" in render | apply | up | down | restart) ;; *) return 125 ;; esac
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' kind && IFS= read -r -d '' argument &&
            IFS= read -r -d '' native_yes && IFS= read -r -d '' native_dry_run &&
            IFS= read -r -d '' native_porcelain && IFS= read -r -d '' native_rc &&
            [ "$native_rc" = 0 ] && { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0%d\0' "$verb" "$#" || producer_rc=$?
            if [ "$#" -gt 0 ]; then printf '%s\0' "$@" || producer_rc=$?; fi
            printf '%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=lifecycle-options "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$native_yes:$native_dry_run:$native_porcelain" in
    0:0:0 | 0:0:1 | 0:1:0 | 0:1:1 | 1:0:0 | 1:0:1 | 1:1:0 | 1:1:1) ;;
    *) return 125 ;;
    esac
    case "$kind" in
    ok)
        [ -z "$argument" ] || return 125
        ;;
    unknown) ;;
    porcelain-needs-dry-run) [ -z "$argument" ] || return 125 ;;
    *) return 125 ;;
    esac
    if [ "$verb" = apply ]; then
        assume_yes=$native_yes
        dry_run=$native_dry_run
        porcelain=$native_porcelain
        if [ "$kind" = unknown ]; then arg=$argument; elif [ "$#" -gt 0 ]; then arg=${!#}; fi
    elif [ "$native_yes:$native_dry_run:$native_porcelain" != 0:0:0 ]; then
        return 125
    fi
    case "$kind:$verb" in
    ok:*) return 0 ;;
    unknown:apply) error "Unknown option for apply: $argument. Run '$0 help'." ;;
    unknown:restart)
        error "restart takes no argument, 'tor' (fresh Tor circuits when clearnet egress is stuck), or 'monerod' (re-dial peers after a Tor restart left the node out of sync). Got: '$argument'."
        ;;
    unknown:render | unknown:up | unknown:down)
        error "Unknown option for $verb: '$argument'. This command takes no options. Run '$0 $verb -h' or '$0 help'."
        ;;
    porcelain-needs-dry-run:apply) error "--porcelain only makes sense with --dry-run." ;;
    *) return 125 ;;
    esac
}
