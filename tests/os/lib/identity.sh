# shellcheck shell=bash
_identity_snapshot() {
    local snapshot field
    snapshot=$(_ssh bash -s <"$SCRIPT_DIR/identity-snapshot-guest.sh") || return 1
    for field in config env machine ssh wallet tor env_project env_other selected_project; do
        [ "$(printf '%s\n' "$snapshot" | grep -Ec "^$field=[0-9a-f]{64}$")" = 1 ] || return 1
    done
    [ "$(printf '%s\n' "$snapshot" | grep -Ec '^env_project_present=[01]$')" = 1 ] || return 1
    [ "$(printf '%s\n' "$snapshot" | grep -Ec '^source_commit=[0-9a-f]{40}$')" = 1 ] || return 1
    [ "$(printf '%s\n' "$snapshot" | wc -l | tr -d ' ')" = 11 ] || return 1
    printf '%s\n' "$snapshot"
}
_identity_unchanged() {
    local label="$1" before="$2" after field changed="" detail="" project="equal" other="equal"
    local old_source new_source selected project_introduction=eb30eff24d6d542d23c6c103a586c8f3b6f01124
    if [ -z "$before" ]; then
        bad "$label: identity baseline is missing"
        return 1
    fi
    if ! after=$(_identity_snapshot); then
        bad "$label: identity snapshot could not be read"
        return 1
    fi
    if [ "$before" = "$after" ]; then
        ok "$label: config, env, wallets, Tor keys, machine-id and SSH identity are unchanged"
        return
    fi
    for field in config env machine ssh wallet tor selected_project; do
        if [ "$(printf '%s\n' "$before" | grep "^$field=")" != "$(printf '%s\n' "$after" | grep "^$field=")" ]; then
            changed="${changed:+$changed, }$field"
        fi
    done
    if [ "$(printf '%s\n' "$before" | grep '^env=')" != "$(printf '%s\n' "$after" | grep '^env=')" ]; then
        if [ "$(printf '%s\n' "$before" | grep '^env_project_present=')" != "$(printf '%s\n' "$after" | grep '^env_project_present=')" ]; then
            project=removed
            printf '%s\n' "$after" | grep -qx 'env_project_present=0' || project=added
        elif [ "$(printf '%s\n' "$before" | grep '^env_project=')" != "$(printf '%s\n' "$after" | grep '^env_project=')" ]; then
            project=changed
        fi
        [ "$(printf '%s\n' "$before" | grep '^env_other=')" = "$(printf '%s\n' "$after" | grep '^env_other=')" ] || other=changed
        detail="; project identity: $project; remaining env bytes: $other"
    fi
    if [ -z "$changed" ]; then
        ok "$label: config, env, wallets, Tor keys, machine-id and SSH identity are unchanged"
        return
    fi
    old_source=$(printf '%s\n' "$before" | sed -n 's/^source_commit=//p')
    new_source=$(printf '%s\n' "$after" | sed -n 's/^source_commit=//p')
    selected=$(printf '%s\n' "$before" | sed -n 's/^selected_project=//p')
    if [ "$changed" = env ] && [ "$project" = added ] && [ "$other" = equal ] &&
        [ "$(printf '%s\n' "$after" | grep '^env_project=')" = "env_project=$selected" ] &&
        [ "$(printf '%s\n' "$after" | grep '^selected_project=')" = "selected_project=$selected" ] &&
        git merge-base --is-ancestor "$old_source" "$project_introduction^" >/dev/null 2>&1 &&
        git merge-base --is-ancestor "$project_introduction" "$new_source" >/dev/null 2>&1; then
        ok "$label: identities unchanged except the authorized selected-project addition (#3605)"
        return
    fi
    bad "$label: identity changed (${changed:-snapshot format})$detail"
    return 1
}
