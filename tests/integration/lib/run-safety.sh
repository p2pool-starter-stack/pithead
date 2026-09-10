# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
safety_backup() {
    [ "$SAFETY_BACKUP" = "1" ] || return 0
    it_log "Taking a safety backup before destructive scenarios (pithead backup -y)…"
    if ! pithead backup -y --no-encrypt >"$OUT_DIR/backup.log" 2>&1; then
        it_fail "safety backup created" "see $OUT_DIR/backup.log"
        return 0
    fi
    SAFETY_ARCHIVE="$(rx 'ls -t backups/pithead-backup-*.tar.gz 2>/dev/null | head -n1')"
    if [ -z "$SAFETY_ARCHIVE" ]; then
        it_fail "safety backup archive located" "no backups/pithead-backup-*.tar.gz on the box"
        return 0
    fi
    it_log "Safety backup: $SAFETY_ARCHIVE"
    # Exercise backup as an assertion: the archive must list the core files we'd roll back to.
    local listing
    listing="$(rx "tar -tzf $(quote_arg "$SAFETY_ARCHIVE") 2>/dev/null")"
    assert_contains "backup archive contains config.json" "$listing" "config.json"
    assert_contains "backup archive contains .env" "$listing" ".env"
}

# On a failed run, roll the box back to the pre-test safety backup.
safety_rollback_if_failed() {
    [ "$SAFETY_BACKUP" = "1" ] && [ -n "$SAFETY_ARCHIVE" ] || return 0
    [ "$IT_FAIL" -gt 0 ] || return 0
    it_warn "failures detected — rolling back to the safety backup ($SAFETY_ARCHIVE)…"
    pithead down >/dev/null 2>&1 || true
    if pithead restore -y "$SAFETY_ARCHIVE" >/dev/null 2>&1; then
        pithead up >/dev/null 2>&1 || true
        wait_status_ok 240 || true
        it_log "rollback complete — config/.env/onions/dashboard restored from the pre-test backup."
    else
        it_err "restore FAILED — the box may be in a partial state; archive kept at $SAFETY_ARCHIVE"
        return 0
    fi
}

# Remove the generated safety archive once we're done (kept on --keep, or if restore failed).
safety_cleanup() {
    [ -n "$SAFETY_ARCHIVE" ] || return 0
    if [ "$KEEP_STATE" = "1" ]; then
        it_warn "--keep: leaving the safety backup at $SAFETY_ARCHIVE"
        return 0
    fi
    rx "rm -f $(quote_arg "$SAFETY_ARCHIVE")" >/dev/null 2>&1 || true
    it_step "removed the safety backup archive"
}

# --- Restore + summary ------------------------------------------------------
restore_baseline() {
    [ "$KEEP_STATE" = "1" ] && {
        it_warn "--keep set: leaving the box on the last scenario."
        return
    }
    [ -z "$BASELINE_CONFIG" ] && return
    it_log "Restoring original config.json and re-applying…"
    push_config "$BASELINE_CONFIG"
    pithead apply -y >/dev/null 2>&1 || it_warn "restore apply reported a non-zero exit; check the box."
    wait_status_ok 240 || true
    assert_eq "secrets intact after restore" "$(secret_fingerprint)" "$BASELINE_SECRET_FP"
}

summary() {
    echo ""
    it_log "════════════════ summary ════════════════"
    it_log "passed:  $IT_PASS"
    it_log "skipped: $IT_SKIPPED scenarios, $IT_SKIPPED_PHASES phases, $IT_SKIPPED_LEGS legs"
    # #1083: the totals above say how much did not run; this line says how much of that is a GAP.
    # Five stable skips read as "known and fine" for months precisely because one number could not
    # tell an accepted absence from an uncovered path. Only "missing" is the second kind.
    it_log "  of which: $IT_SKIPPED_MISSING missing (an input would have run it), $IT_SKIPPED_BY_DESIGN by-design (this run's mode excludes it), $IT_SKIPPED_COVERED covered elsewhere"
    # Name what did not run (#1365). The count says how big the hole is; only the names say
    # where it is, and a summary that cannot distinguish "checked and clean" from "never ran"
    # is not a verdict. Goes to stderr with the other warnings so a log split by stream keeps
    # the omissions next to the reasons that caused them.
    if [ -n "$IT_SKIPPED_NAMES" ]; then
        it_warn "did NOT run:"
        echo -e "$IT_SKIPPED_NAMES" >&2
    fi
    if [ "$IT_FAIL" -gt 0 ]; then
        it_err "failed:  $IT_FAIL"
        echo -e "$IT_FAILED_NAMES" >&2
        it_err "Artifacts for failed scenarios are under $OUT_DIR/"
        return 1
    fi
    it_log "failed:  0"
    it_log "All assertions passed. Artifacts/manifest under $OUT_DIR/"
    return 0
}

# --- RigForge integration phase (--rigforge) --------------------------------
# self-skips when the bench has no RigForge feed.
