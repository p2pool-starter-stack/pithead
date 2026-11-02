# shellcheck shell=bash
_scope_keep_running_go() {
    local service_count="$1" binary="${_pithead_go_hybrid_binary:-}" helper_rc=0
    local count native_rc extra index producer_rc=0
    local -a captured=() planned=()
    shift
    for ((index = 0; index < service_count; index++)); do
        captured+=("$1")
        shift
    done
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' count && [ "${#count}" -le 4 ] && [[ "$count" =~ ^(0|[1-9][0-9]*)$ ]] && [ "$count" -le 8193 ] &&
            {
                for ((index = 0; index < count; index++)); do
                    IFS= read -r -d '' "planned[index]" || return 125
                done
            } &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        {
            printf '%s\0%d\0' "$PITHEAD_KEEP_RUNNING" "$#" || producer_rc=$?
            [ "$#" -eq 0 ] || printf '%s\0' "$@" || producer_rc=$?
            printf '%d\0' "$service_count" || producer_rc=$?
            [ "$service_count" -eq 0 ] || printf '%s\0' "${captured[@]}" || producer_rc=$?
            printf '%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=keep-running-scope "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    KEEP_SCOPED_ARGS=("${planned[@]}")
}
