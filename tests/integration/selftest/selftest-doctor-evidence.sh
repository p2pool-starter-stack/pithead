#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-scenario.sh
source "$HERE/../lib/run-scenario.sh"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/doctor-evidence.XXXXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT

echo "== asserted doctor evidence survives later healthy diagnostics =="
IT_PITHEAD=pithead
IT_CURRENT_SCENARIO=check
IT_DASHBOARD_PASSWORD="$(printf '%s-%s' fixture doctor-password)"
IT_SECRET_SENTINEL="$(printf '%s-%s' fixture doctor-token)"
DOCTOR_RC=7
pithead() {
    echo invocation >>"$OUT_DIR/calls"
    printf '%s\n' 'OK egress firewall is installed' 'OK workers can connect' 'OK dashboard answers on 127.0.0.1:8000'
    printf 'WARN LOGIN=%s\n' "$IT_DASHBOARD_PASSWORD"
    printf 'diagnostic stderr TOKEN=%s\n' "$IT_SECRET_SENTINEL" >&2
    return "$DOCTOR_RC"
}
env_on_box() { echo true; }
assert_doctor_ok >"$OUT_DIR/assertion.log"
[ "$IT_FAIL" -eq 1 ] || {
    echo 'doctor failure verdict changed'
    exit 1
}
[ "$(wc -l <"$OUT_DIR/calls")" -eq 1 ] || {
    echo 'doctor was retried'
    exit 1
}
first=("$OUT_DIR"/check/doctor-asserted.*)
[ "${#first[@]}" -eq 1 ] && [ -f "${first[0]}/output.txt" ] || exit 1
[ "$(cat "${first[0]}/exit-code.txt")" = 7 ] || exit 1
expected=$'OK egress firewall is installed\nOK workers can connect\nOK dashboard answers on 127.0.0.1:8000\nWARN LOGIN=<redacted>\ndiagnostic stderr TOKEN=<redacted>'
[ "$(cat "${first[0]}/output.txt")" = "$expected" ] || {
    echo 'asserted output mismatch'
    exit 1
}
grep -q 'expected rc 0, got 7' "$OUT_DIR/assertion.log" || exit 1

# The generic collector runs a second, healthy doctor, not the asserted invocation.
rx() { case "$1" in *doctor*) echo '30 OK, 2 warnings, 0 failures' ;; esac }
api_state() { echo '{}'; }
capture_wallet_diagnostics() { :; }
capture_artifacts check "$OUT_DIR" >/dev/null
[ "$(cat "$OUT_DIR/check/doctor.txt")" = '30 OK, 2 warnings, 0 failures' ] || exit 1
[ "$(cat "${first[0]}/output.txt")" = "$expected" ] || exit 1
[ "$(cat "${first[0]}/exit-code.txt")" = 7 ] || exit 1

# Warnings with exit zero stay successful; another assertion cannot overwrite the first.
DOCTOR_RC=0
assert_doctor_ok >"$OUT_DIR/success.log"
[ "$IT_FAIL" -eq 1 ] || {
    echo 'warnings changed the original verdict'
    exit 1
}
all=("$OUT_DIR"/check/doctor-asserted.*)
[ "${#all[@]}" -eq 2 ] || {
    echo 'later assertion overwrote evidence'
    exit 1
}
[ "$(cat "${first[0]}/exit-code.txt")" = 7 ] || exit 1
grep -q 'doctor exits 0 on a healthy box' "$OUT_DIR/success.log" || exit 1
for dir in "${all[@]}"; do
    if [ "$dir" != "${first[0]}" ]; then
        [ "$(cat "$dir/exit-code.txt")" = 0 ] || exit 1
    fi
done
if grep -F -e "$IT_DASHBOARD_PASSWORD" -e "$IT_SECRET_SENTINEL" "$OUT_DIR"/*.log "$OUT_DIR"/check/doctor-asserted.*/output.txt; then
    echo 'doctor evidence leaked a credential'
    exit 1
fi

echo "== doctor evidence exists before the rc assertion =="
assert_rc() {
    local dirs=("$OUT_DIR"/check/doctor-asserted.*)
    [ "${#dirs[@]}" -eq 3 ] || exit 1
    local dir
    for dir in "${dirs[@]}"; do
        [ -f "$dir/output.txt" ] && [ -f "$dir/exit-code.txt" ] || exit 1
    done
    [ "$2" = 23 ] || exit 1
}
DOCTOR_RC=23
assert_doctor_ok >/dev/null || exit 1

echo "== doctor evidence failures preserve the original rc and redact fail-closed =="
for failure in redact mkdir mktemp write; do
    (
        # Reset the rc assertion after the capture-order observer above.
        assert_rc() { if [ "$2" = "$3" ]; then it_pass "$1"; else it_fail "$1" "expected rc $3, got $2"; fi; }
        IT_FAIL=0
        OUT_DIR="$OUT_DIR/$failure"
        command mkdir -p "$OUT_DIR"
        DOCTOR_RC=19
        case "$failure" in
        redact) redact() {
            cat
            return 1
        } ;;
        mkdir) mkdir() { return 1; } ;;
        mktemp) mktemp() { return 1; } ;;
        write)
            mktemp() {
                local dir
                dir="$(command mktemp "$@")" || return 1
                command mkdir "$dir/output.txt"
                printf '%s\n' "$dir"
            }
            ;;
        esac
        assert_doctor_ok >"$OUT_DIR/failure.log" 2>"$OUT_DIR/capture-error.log"
        [ "$IT_FAIL" -ge 2 ] || exit 1
        grep -q 'doctor assertion evidence captured' "$OUT_DIR/failure.log" || exit 1
        grep -q 'expected rc 0, got 19' "$OUT_DIR/failure.log" || exit 1
        [ "$(wc -l <"$OUT_DIR/calls")" -eq 1 ] || exit 1
        if grep -F -e "$IT_DASHBOARD_PASSWORD" -e "$IT_SECRET_SENTINEL" "$OUT_DIR/failure.log"; then
            echo 'evidence failure leaked doctor output'
            exit 1
        fi
    ) || {
        echo "evidence failure case failed: $failure"
        exit 1
    }
done

echo 'selftest-doctor-evidence: PASS'
