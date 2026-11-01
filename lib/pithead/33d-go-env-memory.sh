_render_env_memory_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" native_rc native_extra candidate_tari candidate_monero
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    {
        IFS= read -r -d '' candidate_tari && IFS= read -r -d '' candidate_monero &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' native_extra && [ -z "$native_extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0' "$TARI_MODE" || producer_rc=$?
            cat "$CONFIG_FILE" || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-env-memory "$binary" settings 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    tari_mem_limit=$candidate_tari monero_mem_limit=$candidate_monero
}

_render_env_memory_limit_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" native_rc native_extra candidate
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' candidate && IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' native_extra && [ -z "$native_extra" ]; }
    } < <(
        local helper_rc=0
        printf '%s\0' "$ram_mb" "$huge_mb" |
            PITHEAD_GO_HELPER=config-env-memory "$binary" limit 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    tari_mem_limit=$candidate
}

_render_env_prep_threads_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" native_rc native_extra candidate
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' candidate && IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' native_extra && [ -z "$native_extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0' "$cores" || producer_rc=$?
            printf '%d\0' "$producer_rc"
        } |
            PITHEAD_GO_HELPER=config-env-resources "$binary" threads 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [[ "$candidate" =~ ^[4-8]$ ]] || return 125
    prep_threads=$candidate
}

_render_env_out_peers_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" native_rc native_extra candidate
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' candidate && IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' native_extra && [ -z "$native_extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0' "$out_peers" || producer_rc=$?
            printf '%d\0' "$producer_rc"
        } |
            PITHEAD_GO_HELPER=config-env-resources "$binary" peers 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    [ "$candidate" = true ] && return 0
    if [ "$candidate" = false ]; then
        error "monero.out_peers must be an integer between 8 and 1024 (got \"$out_peers\")."
        return 0
    fi
    return 125
}
