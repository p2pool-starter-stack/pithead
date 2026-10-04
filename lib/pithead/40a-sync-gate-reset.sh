# shellcheck shell=bash
# Atomic sync-gate marker shared by apply and its privileged retry.
rearm_sync_gate_marker() { # <dashboard-dir> <scope>: atomically plant the reset
    local t marker="$1/sync-gate-reset"
    t=$(mktemp "$1/.sync-gate-reset.XXXXXX") || return 1
    # Never relax an outstanding full reset (including a restore or an older apply).
    if [ "${2:-1}" -eq 2 ] && {
        { [ ! -e "$marker" ] && [ ! -L "$marker" ]; } ||
            { [ -f "$marker" ] && [ ! -L "$marker" ] && grep -qx tari-only "$marker"; }
    }; then
        echo tari-only >"$t"
    fi
    mv -f -T "$t" "$1/sync-gate-reset" || {
        rm -f "$t"
        return 1
    }
}
