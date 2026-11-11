# shellcheck shell=bash
require_complete_verdict() { # <require-complete: 0|1> <missing-skip count> -> verdict on stdout, empty when satisfied
    [ "$1" = 1 ] || return 0
    [ "${2:-0}" -gt 0 ] 2>/dev/null || return 0
    printf 'require-complete: %d row(s) skipped for a missing input — this job must run complete\n' "$2"
    return 1
}
