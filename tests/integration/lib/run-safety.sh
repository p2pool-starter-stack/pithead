# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
safety_backup() {
    [ "$SAFETY_BACKUP" = "1" ] || return 0
    [ "$RUN_IMAGE_UPGRADE" != "1" ] || UPGRADE_TELEMETRY_EPOCH="$(rx 'date +%s')"
    it_log "Taking a safety backup before destructive scenarios (pithead backup -y)…"
    # Read the archive path the CLI itself reports, not `ls -t backups/*` — a concurrent bench
    # run's archive can win that race, and rolling back onto a foreign archive is unrecoverable.
    if ! pithead backup -y --no-encrypt >"$OUT_DIR/backup.log" 2>&1; then
        SAFETY_ARCHIVE="$(sed -n 's/^.*Backup written to: //p' "$OUT_DIR/backup.log" | tail -n1)"
        it_fail "safety backup created" "see $OUT_DIR/backup.log"
        if [ -n "$SAFETY_ARCHIVE" ] && rx "test -f $(quote_arg "$SAFETY_ARCHIVE") && test ! -L $(quote_arg "$SAFETY_ARCHIVE")"; then
            SAFETY_RESTORE_FAILED=1
            it_warn "backup is valid but stack restart failed; retaining $SAFETY_ARCHIVE"
        fi
        return 1
    fi
    SAFETY_ARCHIVE="$(sed -n 's/^.*Backup written to: //p' "$OUT_DIR/backup.log" | tail -n1)"
    if [ -z "$SAFETY_ARCHIVE" ] || ! rx "test -f $(quote_arg "$SAFETY_ARCHIVE") && test ! -L $(quote_arg "$SAFETY_ARCHIVE")"; then
        it_fail "safety backup archive located" "the successful backup did not name a regular archive"
        safety_cleanup
        return 1
    fi
    it_log "Safety backup: $SAFETY_ARCHIVE"
    # Exercise backup as an assertion: the archive must list the core files we'd roll back to.
    # An archive missing either one is not a rollback net, so refuse to run the destructive phases.
    local listing
    listing="$(rx "tar -tzf $(quote_arg "$SAFETY_ARCHIVE") 2>/dev/null")"
    assert_contains "backup archive contains config.json" "$listing" "config.json"
    assert_contains "backup archive contains .env" "$listing" ".env"
    if ! printf '%s\n' "$listing" | grep -q 'config.json' || ! printf '%s\n' "$listing" | grep -q '\.env'; then
        safety_cleanup
        return 1
    fi
    wait_status_ok 240 || {
        it_fail "stack recovered after safety backup" "pithead status did not become healthy"
        safety_restore_exact && safety_cleanup || true
        return 1
    }
    if [ "$RUN_IMAGE_UPGRADE" = "1" ]; then
        if ! UPGRADE_BEFORE_TELEMETRY="$(archived_dashboard_durable_rows "$SAFETY_ARCHIVE" "$UPGRADE_TELEMETRY_EPOCH")" ||
            [ -z "$UPGRADE_BEFORE_TELEMETRY" ]; then
            it_fail "safety archive durable dashboard state is readable" "the archived database or a required table is absent"
            safety_cleanup
            return 1
        fi
    fi
}

# Restore the box to the exact pre-test baseline and VERIFY it landed: config byte-identical and
# every wallet/proxy/dashboard/RPC/onion secret category unchanged. A rollback that is not
# verified is not a rollback — on any failure the archive is retained for manual recovery.
safety_restore_exact() {
    pithead down >/dev/null 2>&1 || true
    if ! pithead restore -y "$SAFETY_ARCHIVE" >/dev/null 2>&1 ||
        ! strict_pithead up >/dev/null 2>&1 || ! wait_status_ok 240 ||
        [ "$(rx 'cat config.json' 2>/dev/null)" != "$BASELINE_CONFIG" ] ||
        [ "$(upgrade_secret_fingerprints)" != "$BASELINE_EXACT_SECRET_FP" ]; then
        SAFETY_RESTORE_FAILED=1
        return 1
    fi
    it_log "rollback complete — exact config and wallet/proxy/dashboard/RPC/onion baseline verified."
    _XVB_RESTORE_ARMED=0
    _SAFETY_RESTORE_ARMED=0
}

# On a failed run, roll the box back to the pre-test safety backup.
safety_rollback_if_failed() {
    [ "$SAFETY_BACKUP" = "1" ] && [ -n "$SAFETY_ARCHIVE" ] || return 0
    [ "$IT_FAIL" -gt 0 ] || return 0
    it_warn "failures detected — rolling back to the safety backup ($SAFETY_ARCHIVE)…"
    safety_restore_exact || {
        it_fail "safety rollback restored the exact healthy baseline" "restore/apply/health/config/secret verification failed; archive retained at $SAFETY_ARCHIVE"
        return 1
    }
}

# EXIT trap for the destructive phases: an interrupted run (Ctrl-C, a cancelled Actions job, a
# SIGTERM from the supervisor) must still put the box back. Chains any EXIT trap already installed
# — e.g. the rig-key ledger's (#1379) — because `trap … EXIT` replaces rather than appends.
safety_abort_restore() {
    local original_rc=$? restore_failed=0
    if [ "$_SAFETY_RESTORE_ARMED" = 1 ]; then
        it_warn "interrupted destructive run — restoring the safety backup"
        safety_restore_exact || restore_failed=1
    fi
    [ -z "$_SAFETY_FOREIGN_TRAP" ] || eval "$_SAFETY_FOREIGN_TRAP"
    [ "$restore_failed" = 0 ] || exit 1
    return "$original_rc"
}

arm_safety_abort_restore() {
    local cur
    cur="$(trap -p EXIT)"
    if [ -n "$cur" ]; then
        local -a parsed
        eval "parsed=($cur)"
        _SAFETY_FOREIGN_TRAP="${parsed[2]}"
    fi
    _SAFETY_RESTORE_ARMED=1
    trap safety_abort_restore EXIT
}

# Remove the generated safety archive once we're done (kept on --keep, or if restore failed).
safety_cleanup() {
    [ -n "$SAFETY_ARCHIVE" ] || return 0
    if [ "$SAFETY_RESTORE_FAILED" != "0" ]; then
        it_warn "retaining the safety backup after a failed rollback: $SAFETY_ARCHIVE"
    elif [ "$KEEP_STATE" = "1" ]; then
        it_warn "--keep: leaving the safety backup at $SAFETY_ARCHIVE"
    else
        rx "rm -f $(quote_arg "$SAFETY_ARCHIVE")" >/dev/null 2>&1 || true
        it_step "removed the safety backup archive"
    fi
}

# --- Restore + summary ------------------------------------------------------
restore_baseline() {
    [ "$KEEP_STATE" = "1" ] && {
        it_warn "--keep set: leaving the box on the last scenario."
        return
    }
    [ -z "$BASELINE_CONFIG" ] && return
    it_log "Restoring original config.json and re-applying…"
    # A restore that reports a warning and moves on leaves the next run on an unknown baseline.
    # Every step is binding, and the config/secret state is re-read and compared afterwards.
    if ! push_config "$BASELINE_CONFIG" || ! pithead apply -y >/dev/null 2>&1 || ! wait_status_ok 240; then
        SAFETY_RESTORE_FAILED=1
        it_fail "restore original config and healthy stack" "config write, apply, or health wait failed; safety archive retained"
        return 1
    fi
    if [ "$(rx 'cat config.json')" != "$BASELINE_CONFIG" ] ||
        [ "$(secret_fingerprint)" != "$BASELINE_SECRET_FP" ]; then
        SAFETY_RESTORE_FAILED=1
        it_fail "restore exact config and secrets" "post-restore verification failed; safety archive retained"
        return 1
    fi
    it_pass "original config and secrets restored exactly"
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
