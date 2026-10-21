# shellcheck shell=bash
_identity_snapshot() {
    local snapshot
    snapshot=$(_ssh bash -s <"$SCRIPT_DIR/identity-snapshot-guest.sh") || return 1
    [ "$(printf '%s\n' "$snapshot" | grep -Ec '^(config|env|machine|ssh|wallet|tor)=[0-9a-f]{64}$')" = 6 ] || return 1
    printf '%s\n' "$snapshot"
}
_identity_unchanged() {
    local label="$1" before="$2" after
    if [ -n "$before" ] && after=$(_identity_snapshot) && [ "$before" = "$after" ]; then
        ok "$label: config, env, wallets, Tor keys, machine-id and SSH identity are unchanged"
    else
        bad "$label: identity changed or a required snapshot could not be read"
        return 1
    fi
}
