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
backup_restart_stack() {
    backup_stack_up && return 0
    backup_diagnose_tor
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
