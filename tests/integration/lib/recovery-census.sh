# shellcheck shell=bash

recovery_project_census() {
    rx "docker ps --all --no-trunc --filter label=com.docker.compose.project=pithead --format '{{.ID}}'"
}

recovery_old_containers_absent() {
    local before="$1" after id
    [ -n "$before" ] || return 1
    after=$(recovery_project_census) || return 1
    while IFS= read -r id; do
        [[ "$id" =~ ^[0-9a-f]{64}$ ]] || return 1
        ! grep -Fxq "$id" <<<"$after" || return 1
    done <<<"$before"
    [ -z "$after" ] || ! grep -vE '^[0-9a-f]{64}$' <<<"$after"
}

recovery_post_op_invariants() {
    local label="$1" before="$2"
    if wait_for 60 5 "old project containers absent" recovery_old_containers_absent "$before"; then
        it_pass "$label: no pre-operation project container survives"
    else
        it_fail "$label: no pre-operation project container survives" "old ID remains or census failed"
        return 1
    fi
    rr_web_ports_owned_by_dashboard "$label"
}
