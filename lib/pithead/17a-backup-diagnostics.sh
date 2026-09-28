# Keep Tor's failure-window evidence before a backup restart retry or the appliance boot path
# changes the container. Diagnostics must not replace the original startup error.
backup_diagnose_tor() {
    warn "Tor after failed backup restart (health and last 40 log lines):"
    docker inspect --format '{{json .State.Health}}' tor 2>&1 | bundle_redact_log || true
    docker logs --tail 40 --timestamps tor 2>&1 | bundle_redact_log || true
}

# Isolate stack_up's exit-based failures so backup can retry and report both outcomes.
backup_stack_up() (
    trap - ERR
    stack_up
)

# A saturated circuit history can leave Tor at 95% bootstrap after a stop/start (#2747).
# The state file is disposable; onion keys live in separate files. Only discard it when the
# failed restart left Tor unhealthy and its recorded history has the observed signature.
backup_recover_tor_state() {
    local state="$TOR_DATA_DIR/state"
    [ "$(docker inspect --format '{{.State.Health.Status}}' tor 2>/dev/null)" = unhealthy ] || return 0
    sudo test -f "$state" && sudo test ! -L "$state" || return 0
    sudo grep -Eq '^CircuitBuildAbandonedCount[[:space:]]+1000$' "$state" || return 0
    if docker compose stop tor && sudo rm -f -- "$state"; then
        warn "Tor circuit history was saturated; discarded its state before the backup restart retry (onion keys preserved)."
    else
        warn "Could not discard saturated Tor circuit state; retrying startup without changing it."
    fi
}

backup_restart_stack() {
    backup_stack_up && return 0
    backup_diagnose_tor
    backup_recover_tor_state
    if is_appliance; then
        warn "The stack did not restart after the backup — retrying through the appliance boot path."
        # The boot unit owns its own mutation window and carries the appliance image registry.
        mutation_lock_release
        sudo systemctl restart pithead-boot.service && return 0
        warn "The appliance boot path also failed to restart the stack."
        return 1
    fi
    warn "The stack did not restart after the backup — retrying the normal startup path once."
    backup_stack_up && return 0
    backup_diagnose_tor
    warn "The stack failed to restart after two attempts."
    return 1
}
