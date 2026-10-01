# shellcheck shell=bash
backup_stack() {
    command -v python3 >/dev/null || die "python3 is required before the safety backup can run."
    log "Taking a safety backup of the live stack (the rollback anchor)"
    # ponytail: --no-encrypt, as v1.4 refuses plaintext unattended without PITHEAD_BACKUP_PASSPHRASE; the anchor stays on the bench. Output kept for the die reason (#2757).
    local out rc=0 && out="$(on_bench "cd '$CANONICAL_DIR' && ./pithead backup -y --no-encrypt 2>&1")" || rc=$?
    [ "$rc" -eq 0 ] || {
        out="$(printf '%s\n' "$out" | python3 -c 'import sys; s = sys.stdin.buffer.read().decode("utf-8", "ignore"); sys.stdout.write("".join(c for c in s if c in "\n\t" or c.isprintable()))' | redact_remote_output)"
        printf '%s\n' "$out" >&2
        die "pithead backup failed (exit $rc): $(printf '%s\n' "$out" | tail -n 20 | paste -sd'|' -)"
    }
    SAFETY_ARCHIVE="$(on_bench "ls -t '$CANONICAL_DIR'/backups/pithead-backup-*.tar.gz 2>/dev/null | head -n1")"
    [ -n "$SAFETY_ARCHIVE" ] || die "Backup ran but produced no archive."
    ok "safety backup: $SAFETY_ARCHIVE"
}
