# shellcheck shell=bash
backup_stack() {
    command -v python3 >/dev/null || die "python3 is required before the safety backup can run."
    log "Taking a safety backup of the live stack (the rollback anchor)"
    backup_window_attempt
    local out rc=0 archive_state=invalid token="" archive_dir before="" after="" new="" census_ok=1
    archive_dir="$CANONICAL_DIR/backups"
    before="$(on_bench "if test -d $(quote_arg "$archive_dir"); then find $(quote_arg "$archive_dir") -mindepth 1 -maxdepth 1 -name 'pithead-backup-*.tar.gz' -printf '%f\\n'; fi" 2>/dev/null)" || census_ok=0
    before="$(printf '%s\n' "$before" | LC_ALL=C sort)" || census_ok=0
    if [ -n "${BACKUP_WINDOW_DIR:-}" ]; then token="${BACKUP_WINDOW_DIR##*backup-window-}"; fi
    out="$(on_bench "cd '$CANONICAL_DIR' && PITHEAD_BACKUP_WINDOW_TOKEN=$(quote_arg "$token") ./pithead backup -y --no-encrypt 2>&1")" || rc=$?
    if [ "$rc" -eq 0 ] && [ "$census_ok" -eq 1 ]; then
        after="$(on_bench "if test -d $(quote_arg "$archive_dir"); then find $(quote_arg "$archive_dir") -mindepth 1 -maxdepth 1 -name 'pithead-backup-*.tar.gz' -printf '%f\\n'; fi" 2>/dev/null)" || census_ok=0
        after="$(printf '%s\n' "$after" | LC_ALL=C sort)" || census_ok=0
        if [ "$census_ok" -eq 1 ]; then
            new="$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))" || census_ok=0
        fi
        if [ "$census_ok" -eq 1 ] && [ -n "$new" ] && [[ "$new" != *$'\n'* ]] &&
            [[ "$new" =~ ^pithead-backup-[A-Za-z0-9._-]{1,128}\.tar\.gz$ ]]; then
            SAFETY_ARCHIVE="$archive_dir/$new"
            if on_bench "test -f $(quote_arg "$SAFETY_ARCHIVE") && ! test -L $(quote_arg "$SAFETY_ARCHIVE") && tar -tzf $(quote_arg "$SAFETY_ARCHIVE") >/dev/null 2>&1"; then archive_state=valid; fi
        fi
    fi
    backup_window_finish "$rc" "$archive_state" "$out"
    [ "$rc" -eq 0 ] || {
        out="$(backup_sanitize_output "$out")"
        printf '%s\n' "$out" >&2
        die "pithead backup failed (exit $rc): $(printf '%s\n' "$out" | tail -n 20 | paste -sd'|' -)"
    }
    [ "$archive_state" = valid ] || die "Backup ran but produced no valid archive."
    ok "safety backup: $SAFETY_ARCHIVE"
    backup_prune on_bench "$CANONICAL_DIR/backups" "$SAFETY_ARCHIVE"
}
