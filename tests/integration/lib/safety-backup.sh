# shellcheck shell=bash
backup_stack() {
    command -v python3 >/dev/null || die "python3 is required before the safety backup can run."
    log "Taking a safety backup of the live stack (the rollback anchor)"
    # ponytail: --no-encrypt, as v1.4 refuses plaintext unattended without PITHEAD_BACKUP_PASSPHRASE; the anchor stays on the bench. Output kept for the die reason (#2757).
    backup_window_attempt
    local out rc=0 archive_state=invalid token="" marker=""
    # This validates a new rollback anchor, independently of diagnostic collection.
    marker="$(on_bench 'mktemp' 2>/dev/null)" || marker=""
    if [ -n "${BACKUP_WINDOW_DIR:-}" ]; then token="${BACKUP_WINDOW_DIR##*backup-window-}"; fi
    out="$(on_bench "cd '$CANONICAL_DIR' && PITHEAD_BACKUP_WINDOW_TOKEN=$(quote_arg "$token") ./pithead backup -y --no-encrypt 2>&1")" || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$marker" ]; then
        SAFETY_ARCHIVE="$(on_bench "ls -t '$CANONICAL_DIR'/backups/pithead-backup-*.tar.gz 2>/dev/null | head -n1")"
        if [ -n "$SAFETY_ARCHIVE" ] && on_bench "test $(quote_arg "$SAFETY_ARCHIVE") -nt $(quote_arg "$marker") && tar -tzf $(quote_arg "$SAFETY_ARCHIVE") >/dev/null 2>&1"; then archive_state=valid; fi
    fi
    [ -z "$marker" ] || on_bench "rm -f -- $(quote_arg "$marker")" >/dev/null 2>&1 || true
    backup_window_finish "$rc" "$archive_state" "$out"
    [ "$rc" -eq 0 ] || {
        out="$(backup_sanitize_output "$out")"
        printf '%s\n' "$out" >&2
        die "pithead backup failed (exit $rc): $(printf '%s\n' "$out" | tail -n 20 | paste -sd'|' -)"
    }
    [ "$archive_state" = valid ] || die "Backup ran but produced no valid archive."
    ok "safety backup: $SAFETY_ARCHIVE"
}
