# shellcheck shell=bash
# Caller-side collection; result files exist before preflight or candidate deployment.
backup_window_init() {
    BACKUP_WINDOW_DIR="$(python3 "$HERE/lib/backup-window.py" init "${IT_BACKUP_WINDOW_DIR:-${CI_ARTIFACTS:-${TMPDIR:-}}}" 2>/dev/null)" || BACKUP_WINDOW_DIR=""
    [ -z "$BACKUP_WINDOW_DIR" ] || python3 "$HERE/lib/backup-window.py" emit "$BACKUP_WINDOW_DIR" || true
}

backup_window_identity() { # <checkout>; fixed lines, validated by the producer
    on_bench "cd $(quote_arg "$1") && { git rev-parse HEAD 2>/dev/null || echo unknown; sha256sum pithead 2>/dev/null | cut -d' ' -f1; if test -d .git || test -f .git; then if test -z \"\$(git status --porcelain --untracked-files=no 2>/dev/null)\"; then echo clean; else echo dirty; fi; else echo unknown; fi; }" 2>/dev/null || printf 'unknown\nunknown\nunknown\n'
}

backup_window_attempt() {
    [ -n "${BACKUP_WINDOW_DIR:-}" ] || return 0
    {
        backup_window_identity "$CANONICAL_DIR"
        backup_window_identity "$RESTORE_DIR"
    } |
        python3 "$HERE/lib/backup-window.py" attempt "$BACKUP_WINDOW_DIR" || true
}

backup_window_finish() { # <original exit> <valid|invalid> <original transcript>
    [ -n "${BACKUP_WINDOW_DIR:-}" ] || return 0
    # Failure to collect diagnostics never replaces the backup's numeric exit status.
    local sanitized
    if sanitized="$(backup_sanitize_output "$3")"; then
        printf '%s\n' "$sanitized" | python3 "$HERE/lib/backup-window.py" diagnostics "$BACKUP_WINDOW_DIR" || true
    fi
    printf '%s\n' "$3" | python3 "$HERE/lib/backup-window.py" finish "$BACKUP_WINDOW_DIR" "$1" "$2" || true
}

backup_sanitize_output() {
    printf '%s\n' "$1" | python3 -c 'import sys; s = sys.stdin.buffer.read().decode("utf-8", "ignore"); sys.stdout.write("".join(c for c in s if c in "\n\t" or c.isprintable()))' | redact_remote_output
}
