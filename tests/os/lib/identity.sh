# shellcheck shell=bash
_identity_snapshot() {
    local snapshot
    snapshot=$(_ssh bash -s <"$SCRIPT_DIR/identity-snapshot-guest.sh") || return 1
    [ "$(printf '%s\n' "$snapshot" | grep -Ec '^(config|env|machine|ssh|wallet|tor)=[0-9a-f]{64}$')" = 6 ] || return 1
    printf '%s\n' "$snapshot"
}
_identity_unchanged() {
    local label="$1" before="$2" after field changed=""
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
    bad "$label: identity changed (${changed:-snapshot format})"
    return 1
}
