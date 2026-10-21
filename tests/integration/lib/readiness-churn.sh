# shellcheck shell=bash
# A status exit alone cannot expose Podman restart loops. Compare consecutive live censuses.
status_churn_snapshot() {
    local ids snapshot
    ids=$(rx 'docker ps -aq --filter label=com.docker.compose.project=pithead') || return 1
    [ -n "$ids" ] || return 1
    # IDs come from the engine, but quote each argument rather than interpolating its output.
    local args="" id
    for id in $ids; do args="$args $(quote_arg "$id")"; done
    snapshot=$(rx "docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' $args") || return 1
    [ -n "$snapshot" ] || return 1
    printf '%s\n' "$snapshot" | sort
}

status_ok_without_churn() {
    local snapshot
    if ! pithead status >/dev/null 2>&1 || ! snapshot=$(status_churn_snapshot); then
        STATUS_OK_SNAPSHOT=""
        return 1
    fi
    local previous="${STATUS_OK_SNAPSHOT:-}"
    STATUS_OK_SNAPSHOT="$snapshot"
    [ -n "$previous" ] && [ "$snapshot" = "$previous" ]
}

status_churn_reset() { STATUS_OK_SNAPSHOT=""; }
