container_restart_snapshot() {
    local engine ids rows id name state count started
    engine=$(container_engine)
    command -v "$engine" >/dev/null 2>&1 || return 1
    ids=$("$engine" compose ps -aq 2>/dev/null) || return 1
    [ -n "$ids" ] || return 0
    # shellcheck disable=SC2086
    rows=$("$engine" inspect --format $'{{.Id}}\t{{.Name}}\t{{.State.Status}}\t{{.RestartCount}}\t{{.State.StartedAt}}' $ids 2>/dev/null) || return 1
    while IFS=$'\t' read -r id name state count started; do
        [[ "$id" =~ ^[0-9a-f]+$ && -n "$name" && -n "$state" && "$count" =~ ^[0-9]+$ && -n "$started" ]] || return 1
    done <<<"$rows"
    printf '%s\n' "$rows"
}

container_restarting_names() {
    local before after id name state count started
    local -A before_count before_started before_name
    before=$(container_restart_snapshot) || return 1
    [ -n "$before" ] || return 0
    sleep 3
    after=$(container_restart_snapshot) || return 1
    [ -n "$after" ] || return 1

    while IFS=$'\t' read -r id name state count started; do
        name=${name#/}
        [[ "$name" =~ ^[0-9a-f]{12}_(.+)$ ]] && name=${BASH_REMATCH[1]}
        before_name["$id"]="$name"
        before_count["$id"]="$count"
        before_started["$id"]="$started"
    done <<<"$before"
    while IFS=$'\t' read -r id name state count started; do
        name=${name#/}
        [ -n "${before_count[$id]+set}" ] || continue
        if [ "$count" -gt "${before_count[$id]}" ] ||
            { [[ "${before_started[$id]}" != 0001-01-01* ]] && [ "$started" != "${before_started[$id]}" ]; }; then
            printf '%s\n' "${before_name[$id]}"
        fi
    done <<<"$after"
}

check_container_restarts() {
    local names name failed=0
    if ! names=$(container_restarting_names); then
        dr_fail "Container restart observation failed — the engine state could not be read twice."
        return 0
    fi
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        dr_fail "$name restarted during the health check — it may be crash-looping."
        failed=1
    done <<<"$names"
    [ "$failed" -eq 0 ] && dr_ok "No containers restarted during the health check."
    return 0
}
