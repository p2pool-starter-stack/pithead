# shellcheck shell=bash
# Recovery operations must not interpolate the Compose model when rendered state is missing.
# The shipped project is pinned to pithead. Include this directory's legacy project only with
# its exact working-directory label, as in the project migration's ownership boundary.
configless_project_ps() { # <ps output flags...> -- [ps filters...]
    local out=() legacy ids
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do out+=("$1"); shift; done
    shift
    docker ps --all "${out[@]}" --filter label=com.docker.compose.project=pithead "$@" || return 1
    legacy=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    if [ -n "$legacy" ] && [ "$legacy" != pithead ]; then
        ids=$(docker ps --all "${out[@]}" --filter "label=com.docker.compose.project=$legacy" \
            --filter "label=com.docker.compose.project.working_dir=$PWD" "$@") || return 1
        [ -z "$ids" ] || printf '%s\n' "$ids"
    fi
}

configless_project_ids() { # [ps filters...]
    configless_project_ps --quiet -- "$@"
}

# Podman rejects status=restarting as an unknown state, so the active census lists every state once
# and filters in the shell: an engine failure still refuses, and no engine-specific state is requested.
configless_active_ids() {
    local rows
    rows=$(configless_project_ps --no-trunc --format '{{.State}} {{.ID}}' --) || return 1
    awk '$1 == "running" || $1 == "restarting" || $1 == "paused" { print $2 }' <<<"$rows"
}

configless_stack_down() {
    local ids paused cid containers=()
    command -v docker >/dev/null 2>&1 || error "Cannot stop the stack because docker is unavailable."
    ids=$(configless_project_ids) || error "Could not list stack containers. Fix Docker access and retry '$0 down'."
    paused=$(configless_project_ids --filter status=paused) || error "Could not check paused stack containers. Nothing was stopped."
    while IFS= read -r cid; do
        [ -z "$cid" ] || docker unpause "$cid" >/dev/null || error "Could not unpause a stack container for shutdown. Retry '$0 down'."
    done <<<"$paused"
    while IFS= read -r cid; do [ -z "$cid" ] || containers+=("$cid"); done <<<"$ids"
    if [ "${#containers[@]}" -gt 0 ]; then
        docker stop "${containers[@]}" && docker rm "${containers[@]}" ||
            error "Stack containers could not be stopped and removed. Retry '$0 down' before restoring."
    fi
    # Repeat the engine census: a failed shutdown or a service started during it is not success.
    ids=$(configless_project_ids) || error "Could not verify stack shutdown. Fix Docker access and retry '$0 down'."
    [ -z "$ids" ] || error "Stack containers remain after shutdown. Retry '$0 down' before restoring."
}

# Keep only locally trusted destination paths, never secrets or archived policy. This owner-only
# record allows a reset to recover custom data paths without trusting paths from the archive.
restore_save_reset_paths() {
    local tmp
    restore_collect_destinations
    tmp=$(mktemp .restore-paths.XXXXXX) || error "Could not preserve restore destinations — configuration was not cleared."
    if ! (
        umask 077
        jq -n --arg install "$PWD" --args '{install:$install, directories:($ARGS.positional|unique)}' \
            "${RESTORE_TRUSTED_DIRS[@]}" >"$tmp"
    ) || ! chmod 600 "$tmp" || ! mv -fT -- "$tmp" .restore-paths; then
        rm -f -- "$tmp"
        error "Could not preserve restore destinations — configuration was not cleared."
    fi
}

restore_reset_paths() {
    local paths path owner mode operator_uid
    [ ! -e .restore-paths ] && [ ! -L .restore-paths ] && return 0
    [ -f .restore-paths ] && [ ! -L .restore-paths ] || error "Unsafe restore destination record. Configure the destination and run '$0 render' before restoring."
    owner=$(stat -c '%u' -- .restore-paths) && mode=$(stat -c '%a' -- .restore-paths) && operator_uid=$(id -u "$REAL_USER") ||
        error "Could not verify restore destination record ownership. Configure the destination and run '$0 render' before restoring."
    { [ "$owner" = 0 ] || [ "$owner" = "$operator_uid" ]; } && [ "$mode" = 600 ] ||
        error "Unsafe restore destination record ownership or permissions. Configure the destination and run '$0 render' before restoring."
    paths=$(jq -er --arg install "$PWD" '
        select(.install == $install) | .directories |
        select(type == "array" and length > 0 and length <= 10) |
        select(all(.[]; type == "string" and (explode | all(.[]; . >= 32 and . != 127)))) | .[]
        ' .restore-paths) || error "Invalid restore destination record. Configure the destination and run '$0 render' before restoring."
    while IFS= read -r path; do
        assert_safe_dir "$path"
        RESTORE_TRUSTED_DIRS+=("$path")
    done <<<"$paths"
}
