# shellcheck shell=bash

doctor() {
    # shellcheck disable=SC2034
    DR_OK=0 DR_WARN=0 DR_FAIL=0
    if [ -n "${DOCTOR_FIXTURE_PROBE_MARKER:-}" ]; then
        printf 'probe\n' >>"$DOCTOR_FIXTURE_PROBE_MARKER"
    fi
    printf 'probe cwd=<%s> ref=<%s>\n' "$PWD" "$0" >&2
    case "${DOCTOR_FIXTURE_CASE:-basic}" in
    basic)
        dr_ok dependency "Ready."
        dr_warn capacity "Almost full."
        dr_info note "For reference."
        ;;
    malformed)
        printf 'malformed probe output\n'
        printf 'ok\tmessage\tid\textra\n' >>"${DR_JSON_FILE:?}"
        printf 'warn\tonly-message\n' >>"$DR_JSON_FILE"
        printf 'info\t<tag>& café \001\tunicode-id\n' >>"$DR_JSON_FILE"
        printf '\n' >>"$DR_JSON_FILE"
        ;;
    nonzero)
        dr_ok first "Passed."
        dr_warn second "Needs attention."
        dr_fail third "Failed."
        dr_info fourth "Recorded."
        printf 'probe direct stderr\n' >&2
        ;;
    abrupt-one)
        printf 'probe exits one\n' >&2
        exit 1
        ;;
    abrupt-twenty-three)
        printf 'probe exits twenty-three\n' >&2
        exit 23
        ;;
    abrupt-term)
        printf 'probe terminates itself\n' >&2
        kill -TERM "$$"
        ;;
    block)
        exec 3<>"${DOCTOR_FIXTURE_FIFO:?}"
        printf '%s\n' "$$" >"${DOCTOR_FIXTURE_PID:?}"
        IFS= read -r _ <&3
        ;;
    *)
        printf 'unknown fixture case: %s\n' "$DOCTOR_FIXTURE_CASE" >&2
        return 64
        ;;
    esac
    if [ -n "${PITHEAD_GO_DOCTOR_DONE:-}" ]; then
        : >"$PITHEAD_GO_DOCTOR_DONE"
    fi
    [ "$DR_FAIL" -gt 0 ] && return 1
    return 0
}
