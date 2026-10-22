# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
UNINSTALL_RECOVERY_DIR=""

_uninstall_restore_cell() {
    local channel archive before config secrets failed_before="$IT_FAIL"
    channel=$(rx 'source ./pithead || exit; if is_appliance; then printf appliance; else printf diy; fi') || return 1
    if [ "$channel" = appliance ]; then
        it_skip_leg "DIY uninstall -> CLI restore" "appliance uses factory-reset; docs/operations.md#what-uninstall-removes" by-design
        return 0
    fi
    [ "$channel" = diy ] || return 1
    before=$(recovery_project_census) && [ -n "$before" ] && config=$(rx 'sha256sum config.json') &&
        secrets=$(upgrade_secret_fingerprints) || return 1
    it_step "DIY uninstall -> encrypted CLI restore and up"
    UNINSTALL_RECOVERY_DIR=$(rx 'umask 077; mktemp -d "${TMPDIR:?}/uninstall-recovery.XXXXXX"') || return 1
    [ -n "$UNINSTALL_RECOVERY_DIR" ] || return 1
    rx "umask 077; openssl rand -hex 32 > $(quote_arg "$UNINSTALL_RECOVERY_DIR/passphrase")" || return 1
    if ! rx "PITHEAD_BACKUP_PASSPHRASE=\$(cat $(quote_arg "$UNINSTALL_RECOVERY_DIR/passphrase")) $IT_PITHEAD backup -y" 2>&1 |
        redact >"$OUT_DIR/uninstall-restore.backup.log"; then
        it_fail "uninstall recovery creates an encrypted backup" "backup failed"
        return 1
    fi
    archive=$(rx 'ls -t backups/pithead-backup-*.tar.gz.enc | head -1') || return 1
    [[ "$archive" == backups/pithead-backup-*.tar.gz.enc ]] || return 1
    rx "mv -- $(quote_arg "$archive") $(quote_arg "$UNINSTALL_RECOVERY_DIR/archive.enc")" || return 1
    archive="$UNINSTALL_RECOVERY_DIR/archive.enc"
    before=$(recovery_project_census) && [ -n "$before" ] || return 1
    if ! pithead uninstall -y 2>&1 | redact >"$OUT_DIR/uninstall-restore.uninstall.log"; then
        it_fail "uninstall recovery removes the stack" "uninstall failed"
        return 1
    fi
    if ! reset_restore_wait_empty 60 || ! rx 'test ! -e .env'; then
        it_fail "uninstall recovery starts without containers or rendered environment" "residue or census failure"
        return 1
    fi
    it_pass "uninstall recovery starts without containers or rendered environment"
    if ! rx "PITHEAD_BACKUP_PASSPHRASE=\$(cat $(quote_arg "$UNINSTALL_RECOVERY_DIR/passphrase")) $IT_PITHEAD restore -y $(quote_arg "$archive") && PITHEAD_PULL=missing $IT_PITHEAD up" 2>&1 |
        redact >"$OUT_DIR/uninstall-restore.restore.log"; then
        it_fail "uninstall recovery restores and starts the stack" "restore or up failed"
        return 1
    fi
    recovery_post_op_invariants "uninstall recovery" "$before" && wait_status_ok 600 || {
        it_fail "uninstall recovery returns a healthy stack" "post-operation invariant failed"
        return 1
    }
    assert_eq "uninstall recovery restores the backup configuration" "$(rx 'sha256sum config.json')" "$config"
    assert_eq "uninstall recovery preserves backup secrets and identities" "$(upgrade_secret_fingerprints)" "$secrets"
    it_skip_leg "DIY uninstall -> wizard setup/restore or Set up again" "appliance-only routes; docs/appliance.md#set-up-again" by-design
    it_skip_leg "DIY factory-reset" "appliance-only operation; docs/appliance.md#starting-over-the-two-resets" by-design
    [ "$IT_FAIL" -eq "$failed_before" ]
}

uninstall_recovery_cleanup() {
    [ -n "${UNINSTALL_RECOVERY_DIR:-}" ] || return 0
    rx "rm -f -- $(quote_arg "$UNINSTALL_RECOVERY_DIR/archive.enc") $(quote_arg "$UNINSTALL_RECOVERY_DIR/passphrase") && rmdir -- $(quote_arg "$UNINSTALL_RECOVERY_DIR")" || return 1
    UNINSTALL_RECOVERY_DIR=""
}

run_uninstall_restore() {
    local result=0
    _uninstall_restore_cell || result=1
    uninstall_recovery_cleanup || result=1
    [ "$result" -ne 0 ] || return 0
    it_fail "uninstall -> CLI restore recovery cell" "preparation, operation, recovery invariant or cleanup failed"
    return 1
}
