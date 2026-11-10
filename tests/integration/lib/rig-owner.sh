# shellcheck shell=bash
RIG_OWNER_SSH_PID=""
RIG_OWNER_HOLD_PID=""

rig_owner_hold() {
    local d ack=""
    [ -z "$RIG_OWNER_SSH_PID" ] || return 0
    d="$(mktemp -d)" && mkfifo "$d/in" "$d/out" || {
        warn "rig owner marker: cannot create fifos under ${TMPDIR:-/tmp}"
        return 1
    }
    ssh "${SSH_OPTS[@]}" "$MINER_HOST" 'm=${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}; trap "sudo -n rm -f \"\$m\"" EXIT; printf "%s\n" "$$" | sudo -n tee "$m" >/dev/null || exit 1; echo RIG_OWNER_OK; cat >/dev/null' <"$d/in" >"$d/out" &
    RIG_OWNER_SSH_PID=$!
    (
        exec >"$d/in"
        exec sleep 2147483647
    ) &
    RIG_OWNER_HOLD_PID=$!
    IFS= read -r ack <"$d/out" || true
    rm -rf "$d"
    if [ "$ack" != "RIG_OWNER_OK" ]; then
        warn "could not write the rig owner marker on $MINER_HOST; a rig lent to bench-ci answers upgrades with busy."
        rig_owner_release
        return 1
    fi
}

rig_owner_release() {
    [ -n "$RIG_OWNER_SSH_PID" ] || return 0
    kill "$RIG_OWNER_HOLD_PID" 2>/dev/null
    wait "$RIG_OWNER_HOLD_PID" 2>/dev/null
    kill "$RIG_OWNER_SSH_PID" 2>/dev/null
    wait "$RIG_OWNER_SSH_PID" 2>/dev/null
    RIG_OWNER_SSH_PID="" RIG_OWNER_HOLD_PID=""
    ssh "${SSH_OPTS[@]}" "$MINER_HOST" 'sudo -n rm -f "${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}"' </dev/null || true
}
