# shellcheck shell=bash
# shellcheck disable=SC2034 # IT_STEP_* are consumed by the lib/run-*.sh callers
it_run_logged() {
    local dir="$1" step="$2" raw rc=0
    shift 2
    IT_STEP_NAME="$step"
    IT_STEP_RC=0
    IT_STEP_LOG=""
    if [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null; then
        raw="$dir/.$step.raw"
        "$@" >"$raw" 2>&1
        rc=$?
        redact <"$raw" >"$dir/$step.log" 2>/dev/null || true
        rm -f "$raw"
        IT_STEP_LOG="$dir/$step.log"
    else
        "$@" >/dev/null 2>&1
        rc=$?
    fi
    if [ "$rc" -ne 0 ] && [ -n "$IT_STEP_LOG" ]; then
        tail -n 15 "$IT_STEP_LOG" | sed 's/^/        /'
    fi
    IT_STEP_RC="$rc"
    return "$rc"
}
it_selfcheck_run_logged() {
    local dir="$1"
    it_step "bounded step-diagnostics self-check (#3641)…"
    it_run_logged "$dir" diag-injected bash -c \
        "printf 'injected step-failure marker\n'; printf 'PASSWORD=injected-fixture-value\n' >&2; exit 42" || true
    if [ "$IT_STEP_RC" = 42 ] && [ "$IT_STEP_NAME" = diag-injected ] && [ -n "$IT_STEP_LOG" ] &&
        grep -q 'injected step-failure marker' "$IT_STEP_LOG" &&
        grep -q 'PASSWORD=<redacted>' "$IT_STEP_LOG" &&
        ! grep -q 'injected-fixture-value' "$IT_STEP_LOG"; then
        it_pass "injected step failure retained its step, rc and sanitized output (#3641)"
    else
        it_fail "injected step failure retained its step, rc and sanitized output (#3641)" \
            "step=[$IT_STEP_NAME] rc=[$IT_STEP_RC] log=[${IT_STEP_LOG:-unavailable}]"
        return 1
    fi
}
