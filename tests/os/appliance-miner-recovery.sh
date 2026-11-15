# shellcheck shell=bash disable=SC2154
miner_guest() {
    local command='bash -s --' arg
    for arg in "$@"; do command+=" $(printf '%q' "$arg")"; done
    _ssh "$command" <"$SCRIPT_DIR/appliance-miner-recovery-leg.sh"
}
miner_backup_trial() {
    local rig=${1:-} identity result name state deadline output rc=0
    # shellcheck disable=SC2034
    local DASH_USER=$dash_user DASH_PASS=$dash_pass
    miner_guest precondition || return 1
    output=$(miner_guest arm "$rig") || rc=$?
    if [ "$rc" = 77 ]; then
        it_skip_leg "local miner strand fidelity (#3375)" "no host LISTEN socket" by-design
        it_skip_leg "local miner backup strand (#3375)" "injection unavailable" by-design
        return 77
    fi
    [ "$rc" = 0 ] || {
        miner_guest cleanup
        return 1
    }
    info "$output"
    if [ -z "$rig" ] && ! miner_guest fidelity; then
        miner_guest cleanup
        return 1
    fi
    if [ -z "$rig" ]; then
        ok "local miner strand persists 180 seconds with recovery paused (#3375)"
        miner_guest arm || {
            miner_guest cleanup
            return 1
        }
    fi
    identity=$(miner_guest identity) || {
        miner_guest cleanup
        return 1
    }
    miner_guest backup-ready || {
        miner_guest cleanup
        return 1
    }
    result=$(dashboard_control_request backup '{}' 420) || {
        miner_guest cleanup
        return 1
    }
    if [ "$(jq -r '.status' <<<"$result")" != applied ]; then
        miner_guest cleanup
        return 1
    fi
    miner_guest backup-applied || {
        miner_guest cleanup
        return 1
    }
    if ! miner_guest verdict "${identity#* }" "$rig"; then
        miner_guest cleanup
        return 1
    fi
    name=$(miner_guest_name) || return 1
    deadline=$(($(date +%s) + 60))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        state=$(dashboard_curl -fsSk -m 8 "https://$ip/api/state" 2>/dev/null) || state='{}'
        if jq -e --arg name "$name" 'any(.workers[]?; .name == $name and .status == "online")' <<<"$state" >/dev/null; then
            ok "local miner reconnects and accepts shares after dashboard backup (#3375)"
            return 0
        fi
        sleep 5
    done
    return 1
}
miner_guest_name() {
    _ssh "jq -er '.pools[0].user' /data/rigforge/data/worker/xmrig/build/config.json"
}
