tor_recovery_bootstrap_persistent() {
    local first second
    first=$(tor_recovery_bootstrap_sample) || return 1
    sleep 180
    second=$(tor_recovery_bootstrap_sample) || return 1
    [ "$first" = "$second" ]
}

tor_recovery_circuit_status() {
    timeout 10 docker exec tor /usr/local/bin/tor-control-signal.sh STATUS 2>/dev/null
}

tor_recovery_circuits_wedged() {
    local status i
    for i in 1 2; do
        status=$(tor_recovery_circuit_status) || return 1
        [[ "$status" =~ ^circuit-established=([01])\ pending=([0-9]+)$ ]] || return 1
        [ "${BASH_REMATCH[1]}" = 0 ] || [ "${BASH_REMATCH[2]}" -ge "$TOR_RECOVERY_PENDING_LIMIT" ] || return 1
        [ "$i" = 2 ] || sleep 60
    done
}

TOR_RECOVERY_CACHE_FILES="cached-microdesc-consensus cached-microdescs cached-microdescs.new cached-certs"
TOR_RECOVERY_CONSENSUS_STALE_SEC=43200

tor_recovery_consensus_age() {
    local file="$1/cached-microdesc-consensus" mtime
    sudo test -f "$file" && sudo test ! -L "$file" || return 1
    mtime=$(sudo stat -c %Y -- "$file") || return 1
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$(($(date +%s) - mtime))"
}

tor_recovery_consensus_stale() {
    local age
    age=$(tor_recovery_consensus_age "$1") || return 1
    [ "$age" -gt "$TOR_RECOVERY_CONSENSUS_STALE_SEC" ]
}

tor_recovery_move_cache() {
    local name
    for name in $TOR_RECOVERY_CACHE_FILES; do
        sudo test -e "$1/$name" || sudo test -L "$1/$name" || continue
        sudo test -f "$1/$name" && sudo test ! -L "$1/$name" || return 1
        sudo test -d "$2" || sudo mkdir -- "$2" || return 1
        sudo mv -n -- "$1/$name" "$2/$name" && sudo test ! -e "$1/$name" || return 1
    done
}

tor_recovery_redial_tari() {
    if docker inspect tari --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
        docker compose restart tari || warn "Tari re-dial failed; restart tari manually."
    fi
}

tor_recovery_unsaturated_reason() {
    local reason
    if tor_recovery_consensus_stale "$1"; then
        printf 'stale-consensus\n'
        return 0
    elif tor_recovery_heal_outage "$(env_get CONTROL_DIR)"; then
        reason=sustained-outage
    elif tor_recovery_circuits_wedged; then
        reason=circuits-pending
    elif tor_recovery_bootstrap_persistent; then
        reason=bootstrap-stalled
    else
        return 1
    fi
    tor_recovery_egress_down || return 1
    printf '%s\n' "$reason"
}
