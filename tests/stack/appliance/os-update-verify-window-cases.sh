# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is sourced by test-appliance-os-update-lock.sh — run tests/stack/run.sh}"
: "${SANDBOX:?}"
: "${STACK:?}"
: "${ROOT:?}"

echo "== black-box: os-reboot refuses while this machine already runs the in-flight target (#3909) =="
OSWSYS="$OSL/bin/systemctl"
cat >"$OSWSYS" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"${SYSTEMCTL_LOG:-/dev/null}"
exit 0
EOF
OSWAUDIT="$OSL/data/control/audit/control.log"
OSWLOG="$OSL/systemctl.log"
osw_reset() {
    rm -f "$OSLRES/$ULOCK.json" "$OSLDIR/in-flight.json"
    : >"$OSWLOG"
}
osw_reset
jq -n '{step:"reboot-pending",version:"1.3.1",from:"1.2.0"}' >"$OSLSTATE"
jq -n --argjson ts "$(date +%s)" '{from:"1.2.0",to:"1.3.1",ts:$ts}' >"$OSLDIR/in-flight.json"
osl_intent "$ULOCK" os-reboot
oslrun SYSTEMCTL_LOG="$OSWLOG" >/dev/null
assert_eq "the reboot is refused, not failed" "$(osl_st)" "rejected"
assert_contains "the refusal names the version already running" "$(osl_err)" "already running v1.3.1"
assert_contains "the refusal says what a reboot now would do" "$(osl_err)" "take the machine back to the previous version"
assert_contains "the refusal says what to do instead" "$(osl_err)" "Leave it running"
assert_eq "no reboot order was given" "$(grep -c 'systemctl reboot' "$OSWLOG" || true)" "0"
assert_eq "the in-flight flag survives the refusal (verification is still in progress)" \
    "$([ -f "$OSLDIR/in-flight.json" ] && echo present || echo absent)" "present"
assert_eq "the persisted step is untouched" "$(jq -r '.step' "$OSLSTATE" 2>/dev/null)" "reboot-pending"
assert_contains "the refusal is audited" "$(cat "$OSWAUDIT")" '"action":"os-reboot","status":"rejected"'

echo "== black-box: os-reboot refuses while the new slot's health gate is still deciding (#3909) =="
osw_reset
jq -n '{step:"verifying",version:"9.9.9",from:"1.3.1"}' >"$OSLSTATE"
jq -n --argjson ts "$(date +%s)" '{from:"1.3.1",to:"9.9.9",ts:$ts,gate:"started"}' >"$OSLDIR/in-flight.json"
osl_intent "$ULOCK" os-reboot
oslrun SYSTEMCTL_LOG="$OSWLOG" >/dev/null
assert_eq "the reboot is refused" "$(osl_st)" "rejected"
assert_contains "the refusal names the verification in progress" "$(osl_err)" "being verified"
assert_contains "the refusal says a reboot now would interrupt it" "$(osl_err)" "would interrupt it"
assert_eq "no reboot order was given" "$(grep -c 'systemctl reboot' "$OSWLOG" || true)" "0"
assert_eq "the persisted step is untouched" "$(jq -r '.step' "$OSLSTATE" 2>/dev/null)" "verifying"

echo "== black-box: the refusal is bounded to the verify window — the ordinary reboot-pending reboot still reboots (#3909) =="
osw_reset
jq -n '{step:"reboot-pending",version:"9.9.9",from:"1.3.1"}' >"$OSLSTATE"
jq -n --argjson ts "$(date +%s)" '{from:"1.3.1",to:"9.9.9",ts:$ts}' >"$OSLDIR/in-flight.json"
osl_intent "$ULOCK" os-reboot
oslrun SYSTEMCTL_LOG="$OSWLOG" >/dev/null
assert_eq "the reboot proceeds" "$(osl_st)" "rebooting"
assert_contains "systemctl reboot was actually ordered" "$(cat "$OSWLOG")" "systemctl reboot"
assert_contains "the proceed is audited" "$(cat "$OSWAUDIT")" '"action":"os-reboot","status":"rebooting"'
unset -f osw_reset

echo "== unit: the new slot moves the persisted step to verifying before anything else on the boot reads it (#3909) =="
OSV="$SANDBOX/os-verify-window"
osv_run() {
    rm -rf "$OSV"
    mkdir -p "$OSV/data/os-update" "$OSV/data/control/results"
    printf '%s\n' "$1" >"$OSV/VERSION"
    if [ -n "$2" ]; then
        printf '{"from":"1.0.0","to":"%s"}\n' "$2" >"$OSV/data/os-update/in-flight.json"
        jq -n --arg t "$2" '{step:"reboot-pending",version:$t,from:"1.0.0"}' \
            >"$OSV/data/control/results/os-update-state.json"
    fi
    (
        cd "$OSV" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        OS_INFLIGHT=data/os-update/in-flight.json
        OS_STATE_DIR=data/control/results
        os_update_verifying_state >/dev/null
    )
    local state="$OSV/data/control/results/os-update-state.json"
    if [ ! -f "$state" ]; then
        printf '||absent\n'
        return 0
    fi
    printf '%s|%s|%s|present\n' \
        "$(jq -r '.step // ""' "$state")" \
        "$(jq -r '.gate // ""' "$OSV/data/os-update/in-flight.json" 2>/dev/null)" \
        "$(jq -r '.version // ""' "$state")"
}
assert_eq "a boot running the in-flight target takes the step off reboot-pending and stamps the gate decided" \
    "$(osv_run 1.2.4 1.2.4)" "verifying|started|1.2.4|present"
assert_eq "a boot that is NOT the target changes neither the step nor the flag" \
    "$(osv_run 1.3.1 9.9.9)" "reboot-pending||9.9.9|present"
assert_eq "no in-flight flag writes no OS-update state" "$(osv_run 1.2.4 "")" "||absent"
unset -f osv_run

echo "== unit: the fallback verdict separates a gate that never judged from one that judged (#3909) =="
OSR="$SANDBOX/os-rollback-gate"
osr_run() {
    rm -rf "$OSR"
    mkdir -p "$OSR/data/os-update" "$OSR/data/control/results"
    printf '%s\n' "$1" >"$OSR/VERSION"
    if [ -n "$2" ]; then
        local extra=""
        [ -n "$3" ] && extra=",\"gate\":\"$3\""
        [ -n "${4:-}" ] && extra="$extra,\"blocking\":$4"
        printf '{"from":"1.0.0","to":"%s"%s}\n' "$2" "$extra" >"$OSR/data/os-update/in-flight.json"
    fi
    (
        cd "$OSR" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        OS_INFLIGHT=data/os-update/in-flight.json
        OS_STATE_DIR=data/control/results
        os_update_rollback_verdict >"$OSR/console.txt" 2>&1
    )
    local state="$OSR/data/control/results/os-update-state.json"
    if [ ! -f "$state" ]; then
        printf 'none|\n'
        return 0
    fi
    printf '%s|%s|%s\n' \
        "$(jq -r '.verdict.interrupted' "$state")" \
        "$(jq -r '.verdict.outcome // ""' "$state")" \
        "$(jq -r '.verdict.blocking[0] // ""' "$state")"
}
assert_eq "a gate that started but never decided reads as interrupted, with the cause named" \
    "$(osr_run 1.0.0 1.0.1 started)" "true|rolled_back|interrupted before the update was verified"
assert_contains "the interrupted verdict says the checks never reached a verdict, not that they failed" \
    "$(cat "$OSR/console.txt")" "never reached a verdict"
assert_eq "a gate that JUDGED keeps its blocking list and is not interrupted" \
    "$(osr_run 1.0.0 1.0.1 failed '["the dashboard never answered"]')" "false|rolled_back|the dashboard never answered"
assert_contains "the judged verdict names what held the gate" \
    "$(cat "$OSR/console.txt")" "its gate was held by: the dashboard never answered"
assert_eq "a flag with no gate stamp (written by an older image) falls to interrupted, never to an empty list" \
    "$(osr_run 1.0.0 1.0.1 "")" "true|rolled_back|interrupted before the update was verified"
assert_eq "a boot running the target version is a no-op here — the commit gate owns the success verdict" \
    "$(osr_run 1.0.1 1.0.1 started)" "none|"
assert_eq "no in-flight flag is a no-op" "$(osr_run 1.0.0 "")" "none|"
unset -f osr_run

echo "== unit: a failed health gate stamps the flag FAILED, and the fallback boot after it reads as judged (#3909) =="
OSFB="$SANDBOX/os-verify-window-failboot"
rm -rf "$OSFB"
mkdir -p "$OSFB/data/os-update" "$OSFB/data/control/results"
printf '1.2.4\n' >"$OSFB/VERSION"
printf '{"from":"1.2.3","to":"1.2.4"}\n' >"$OSFB/data/os-update/in-flight.json"
(
    cd "$OSFB" || exit 1
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    OS_INFLIGHT=data/os-update/in-flight.json
    OS_STATE_DIR=data/control/results
    BOOT_DOCTOR_JSON="$OSFB/doctor.json"
    PITHEAD_REBOOT_CMD="touch $OSFB/rebooted" fail_boot "the stack never became healthy (serving + doctor + status)"
) >/dev/null 2>&1 || true
assert_eq "the failed health gate stamps gate=failed on the in-flight flag" \
    "$(jq -r '.gate // "none"' "$OSFB/data/os-update/in-flight.json")" "failed"
printf '1.2.3\n' >"$OSFB/VERSION"
osf_console=$(
    cd "$OSFB" || exit 1
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    OS_INFLIGHT=data/os-update/in-flight.json
    OS_STATE_DIR=data/control/results
    os_update_rollback_verdict 2>&1
)
assert_eq "the fallback boot after a judged failure reads as judged, not interrupted" \
    "$(jq -r '.verdict.interrupted' "$OSFB/data/control/results/os-update-state.json")" "false"
assert_contains "and it says the bootloader fell back" "$osf_console" "the bootloader fell back"
assert_not_contains "it does not claim an interruption" "$osf_console" "interrupted"
rm -rf "$OSFB"
unset osf_console
