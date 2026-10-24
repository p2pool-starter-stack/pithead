# shellcheck shell=bash
redact_restore_output() {
    sed -E 's/(Stratum password:).*/\1 <redacted>/; s/(connect with pass ).*/\1<redacted>/' | redact
}

restore_operation() {
    local stage="$1" operation_rc=0 writer capture_rc=0
    shift
    if [ -n "${OUT_DIR:-}" ] && printf '\noperation=%s output_tail_bytes=65536\n' "$stage" >>"$OUT_DIR/restore-operations.log"; then
        {
            writer=$!
            "$@" || operation_rc=$?
        } > >(
            set -o pipefail
            redact_restore_output | tail -c 65536 >>"$OUT_DIR/restore-operations.log"
        ) 2>&1
        wait "$writer" || capture_rc=$?
        printf '\noperation=%s exit=%s\n' "$stage" "$operation_rc" >>"$OUT_DIR/restore-operations.log" || capture_rc=1
    else
        capture_rc=1
        "$@" >/dev/null 2>&1 || operation_rc=$?
    fi
    [ "$capture_rc" = 0 ] || printf 'restore diagnostic: %s artifact unavailable (exit %s)\n' "$stage" "$operation_rc" >&2
    [ "$operation_rc" = 0 ] || printf 'restore operation failed: %s (exit %s); see restore-operations.log\n' "$stage" "$operation_rc" >&2
    return "$operation_rc"
}

run_restore_diagnostic_control() {
    local operation_rc=0 cleanup_rc=0 diagnostic control_dir="$OUT_DIR/restore-diagnostic-control"
    if ! mkdir -p "$control_dir" || ! : >"$control_dir/restore-operations.log"; then
        it_fail "restore diagnostic control initialized (#3641)" "control artifact unavailable"
        return 1
    fi
    OUT_DIR="$control_dir" restore_operation control.restore rx "printf '%s\n' 'injected restore stdout'; printf '%s\n' 'injected restore stderr' >&2; (exit 73)" || operation_rc=$?
    OUT_DIR="$control_dir" restore_operation control.cleanup rx "printf '%s\n' 'injected cleanup stderr' >&2; (exit 74)" || cleanup_rc=$?
    diagnostic="$(cat "$control_dir/restore-operations.log" 2>/dev/null)"
    if [ "$operation_rc:$cleanup_rc" = 73:74 ] &&
        [[ "$diagnostic" == *'operation=control.restore exit=73'* ]] &&
        [[ "$diagnostic" == *'injected restore stdout'* ]] &&
        [[ "$diagnostic" == *'injected restore stderr'* ]] &&
        [[ "$diagnostic" == *'operation=control.cleanup exit=74'* ]] &&
        [[ "$diagnostic" == *'injected cleanup stderr'* ]]; then
        it_pass "restore diagnostics retain the originating failure after cleanup failure (#3641)"
    else
        it_fail "restore diagnostics retain the originating failure after cleanup failure (#3641)" "bounded remote control did not retain both operations and exit statuses"
        return 1
    fi
}
