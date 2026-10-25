# shellcheck shell=bash
_identity_snapshot() {
    local snapshot field
    snapshot=$(_ssh bash -s <"$SCRIPT_DIR/identity-snapshot-guest.sh") || return 1
    for field in config env machine ssh wallet tor env_project env_other; do
        [ "$(printf '%s\n' "$snapshot" | grep -Ec "^$field=[0-9a-f]{64}$")" = 1 ] || return 1
    done
    [ "$(printf '%s\n' "$snapshot" | grep -Ec '^env_project_present=[01]$')" = 1 ] || return 1
    [ "$(printf '%s\n' "$snapshot" | wc -l | tr -d ' ')" = 9 ] || return 1
    printf '%s\n' "$snapshot"
}
_identity_unchanged() {
    local label="$1" before="$2" after field changed="" detail="" project="equal" other="equal"
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
    for field in config env machine ssh wallet tor; do
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
    bad "$label: identity changed (${changed:-snapshot format})$detail"
    return 1
}
