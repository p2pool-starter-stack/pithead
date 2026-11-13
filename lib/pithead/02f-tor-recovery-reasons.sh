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

tor_recovery_unsaturated_reason() {
    local reason
    if tor_recovery_heal_outage "$(env_get CONTROL_DIR)"; then
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
