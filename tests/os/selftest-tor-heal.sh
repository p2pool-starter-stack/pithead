#!/usr/bin/env bash
# Pure harness controls: no containers, guests or network service.
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/tmp}}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/tor-heal-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2034 # sourced phase reads both globals.
OS_RUN_SUITE=1 SCRIPT_DIR="$ROOT/tests/os"
# shellcheck source=tests/os/phases/tor-heal.sh
source "$ROOT/tests/os/phases/tor-heal.sh"
ok() { printf '%s\n' "$*" >>"$work/pass"; }
bad() { printf '%s\n' "$*" >>"$work/fail"; }
_phase_provision_initial() { return "${provision_rc:-0}"; }
_ssh() {
    [ "$SSH_TIMEOUT" = 13000 ] && [ "$1" = 'timeout 12500 bash -s' ]
    cat >"$work/guest-script"
    return "${guest_rc:-0}"
}
phase_tor_heal
cmp "$ROOT/tests/os/tor-heal-guest.sh" "$work/guest-script"
grep -q '#3118' "$work/pass"
rm "$work/guest-script"
provision_rc=1
if phase_tor_heal; then exit 1; fi
[ ! -e "$work/guest-script" ]
provision_rc=0 guest_rc=17
SSH_ERR="$work/ssh-err"
echo 'Tor heal guest failed at fixture-stage (line 1, exit 17)' >"$SSH_ERR"
phase_tor_heal >"$work/phase-output"
grep -q 'Guest stderr: Tor heal guest failed at fixture-stage' "$work/phase-output"
[ "$(wc -l <"$work/fail" | tr -d " ")" = 2 ]
# A Docker command that accepts no stdin must not make the offline test pass.
docker() {
    case " $* " in
    *' -i '*)
        cat >/dev/null
        echo 'Tor offline recovery assertions complete'
        ;;
    *) return 0 ;;
    esac
}
export -f docker
bash "$ROOT/tests/stack/standalone/test_tor_saturated_image.sh" fixture >"$work/image-output"
sed 's/docker run -i /docker run /' "$ROOT/tests/stack/standalone/test_tor_saturated_image.sh" >"$work/broken-image-test.sh"
if bash "$work/broken-image-test.sh" fixture >"$work/broken-output"; then
    echo 'offline image test accepted missing Docker stdin' >&2
    exit 1
fi
# The dashboard sends webhooks from the host network, so the guest sink must be a loopback one.
awk '/^  dashboard:/{d=1} d&&/network_mode:/{print; exit}' "$ROOT/docker-compose.yml" | grep -q '"host"'
grep -qx 'gateway=127.0.0.1' "$ROOT/tests/os/tor-heal-guest.sh"
# Exercise guest helpers without executing the guest's main body.
(
    timeout() {
        [ "$1" = 20 ] || return 23
        shift
        [ "${inspect_timeout_rc:-0}" = 0 ] || return "$inspect_timeout_rc"
        "$@"
    }
    docker() {
        [ "$1" = inspect ] && [ "$2" = --format ] && [ "$4" = tor ] || return 23
        if [ "$3" = '{{.State.StartedAt.Unix}}' ]; then
            printf '%s\n' "$epoch"
        else
            printf '2026-10-23 04:51:18.540016744 +0000 UTC\n'
        fi
    }
    eval "$(sed -n '/^container_start() {/,/^}/p' "$ROOT/tests/os/tor-heal-guest.sh")"
    epoch=1792731078
    [ "$(container_start tor)" = "$epoch" ]
    for epoch in '' 0 invalid; do
        if container_start tor; then exit 1; fi
    done
    epoch=1792731078 inspect_timeout_rc=124
    if container_start tor; then exit 1; fi
)
(
    work="$work/egress"
    mkdir -p "$work"
    timeout() {
        [ "$1" = 60 ] || return 23
        shift
        [ "${probe_timeout_rc:-0}" = 0 ] || return "$probe_timeout_rc"
        "$@"
    }
    docker() {
        if [ "$1 $2" = 'exec tor' ]; then
            printf '250 OK\n250 OK\n250 DisableNetwork=%s\n' "$network_disabled"
        else
            [ "$1 $2 $3" = 'exec dashboard python3' ] || return 23
            printf 'EGRESS_%s\n' "$probe_state"
            return "$probe_rc"
        fi
    }
    sleep() { :; }
    eval "$(sed -n '/^egress() {/,/^}/p' "$ROOT/tests/os/tor-heal-guest.sh")"
    eval "$(sed -n '/^require_egress_down() {/,/^}/p' "$ROOT/tests/os/tor-heal-guest.sh")"
    eval "$(sed -n '/^disable_network() {/,/^}/p' "$ROOT/tests/os/tor-heal-guest.sh")"
    network_disabled=1 probe_rc=0 probe_state=DOWN
    disable_network
    probe_state=UP
    if disable_network; then exit 1; fi
    probe_state=DOWN probe_rc=17
    if disable_network; then exit 1; fi
    network_disabled=0 probe_rc=0
    if disable_network; then exit 1; fi
    network_disabled=1 probe_timeout_rc=124
    if disable_network; then exit 1; fi
)
(
    control="$work/actions"
    mkdir -p "$control/audit" "$control/results"
    # shellcheck disable=SC2034 # extracted audit helper reads this guest global.
    since=2026-01-01T00:00:00Z
    eval "$(sed -n '/^applied_heals() {/,/^}/p' "$ROOT/tests/os/tor-heal-guest.sh")"
    eval "$(sed -n '/^confirmed_newnyms() {/,/^}/p' "$ROOT/tests/os/tor-heal-guest.sh")"
    printf '%s\n' '{"ts":"2025-12-31T23:59:59Z","id":"old","actor":"tor-heal","action":"tor-newnym","status":"applied"}' >"$control/audit/control.log"
    if confirmed_newnyms; then exit 1; fi
    for id in first second; do
        jq -nc --arg id "$id" '{ts:"2026-01-01T00:01:00Z",id:$id,actor:"operator",action:"tor-newnym",status:"applied"}' >>"$control/audit/control.log"
    done
    if confirmed_newnyms; then exit 1; fi
    sed 's/"operator"/"tor-heal"/g' "$control/audit/control.log" >"$control/audit/next"
    mv "$control/audit/next" "$control/audit/control.log"
    if confirmed_newnyms 2>/dev/null; then exit 1; fi
    printf '{"status":"applied","action":"tor-newnym"}\n' >"$control/results/first.json"
    printf '{"status":"rejected","action":"tor-newnym"}\n' >"$control/results/second.json"
    if confirmed_newnyms; then exit 1; fi
    cp "$control/results/first.json" "$control/results/second.json"
    confirmed_newnyms
)
(
    work="$work/configure"
    mkdir -p "$work/stack"
    cd "$work/stack"
    printf '{}\n' >config.json
    cat >pithead <<'STUB'
#!/usr/bin/env bash
[ "$*" = 'apply -y' ] || exit 23
STUB
    chmod +x pithead
    # shellcheck disable=SC2034 # extracted configure() reads this guest global.
    gateway=192.0.2.1
    eval "$(sed -n '/^configure() {/,/^}/p' "$ROOT/tests/os/tor-heal-guest.sh")"
    configure false
    jq -e '.tor.auto_heal == false and .notifications.tor == false and .dashboard.auth.password == "" and .dashboard.control.enabled == false' config.json >/dev/null
    configure true
    jq -e '.tor.auto_heal == true and (.notifications.webhooks | length == 1) and .dashboard.auth.password == "" and .dashboard.control.enabled == false' config.json >/dev/null
)

(
    work="$work/recovery-diagnostics"
    control="$work/control-diagnostics"
    mkdir -p "$work" "$control/audit"
    printf '{"text":"unrelated fixture-private-identifier"}\n' >"$work/alerts.jsonl"
    printf '%s\n' '{"ts":"2026-01-01T00:01:00Z","actor":"tor-heal","action":"tor-newnym","status":"rejected","keys":"fixture-private-identifier"}' >"$control/audit/control.log"
    # shellcheck disable=SC2034 # extracted recovery diagnostics read these guest globals.
    since=2026-01-01T00:00:00Z tor_started=100 monero_started=200
    confirmed_newnyms() { return 1; }
    container_start() { if [ "$1" = tor ]; then echo 300; else echo 400; fi; }
    egress() { return 2; }
    timeout() {
        [ "$1" = 20 ]
        shift
        "$@"
    }
    docker() {
        case "$1" in
        inspect) echo unhealthy ;;
        exec) echo '{"outgoing":0,"private":"fixture-private-identifier"}' ;;
        logs)
            echo 'unrelated fixture-private-identifier'
            for ((n = 0; n < 60; n++)); do
                echo '2026-01-01 00:01:00,000 [WARNING] Tor NEWNYM was not confirmed by the host control runner' >&2
            done
            ;;
        esac
    }
    eval "$(sed -n '/^recovery_diagnostics() {/,/^}/p' "$ROOT/tests/os/tor-heal-guest.sh")"
    recovery_diagnostics >"$work/predicates"
    grep -q 'confirmed_newnyms=0 probe_rc=2 recovery_notices=0' "$work/predicates"
    grep -q 'tor=100->300 monerod=200->400' "$work/predicates"
    grep -q 'health=unhealthy outgoing=0' "$work/predicates"
    jq -e '(keys | sort) == ["action","status","ts"] and .status == "rejected"' "$work/recovery-audit.log" >/dev/null
    [ "$(wc -l <"$work/healer.log" | tr -d ' ')" = 50 ]
    if grep -q 'fixture-private-identifier' "$work/predicates" "$work/recovery-audit.log" "$work/healer.log"; then exit 1; fi
)
(
    work="$work/recovery-verdict"
    mkdir -p "$work"
    printf '{"text":"egress recovered following Tor restart;"}\n' >"$work/alerts.jsonl"
    recovery_diagnostics() { echo captured >"$work/recovery-captured"; }
    confirmed_newnyms() { return 0; }
    container_start() {
        [ "$1" != "$inspect_fail" ] || return 124
        if [ "$1" = tor ]; then echo 300; else echo 400; fi
    }
    egress() { return 0; }
    docker() {
        if [ "$1" = inspect ]; then echo healthy; else echo '{"outgoing":1}'; fi
    }
    date() { cat "$work/clock"; }
    sleep() { echo 3 >"$work/clock"; }
    export -f recovery_diagnostics confirmed_newnyms container_start egress docker date sleep
    export work deadline=2 tor_started=100 monero_started=200
    sed -n '/^stage=host-recovery/,/^stage=verify-recovery/p' "$ROOT/tests/os/tor-heal-guest.sh" >"$work/recovery-verdict.sh"
    for inspect_fail in tor monerod none; do
        export inspect_fail
        rm -f "$work/recovery-captured"
        echo 1 >"$work/clock"
        if bash -e "$work/recovery-verdict.sh"; then
            [ "$inspect_fail" = none ]
            [ ! -e "$work/recovery-captured" ]
        else
            [ "$inspect_fail" != none ]
            grep -qx captured "$work/recovery-captured"
        fi
    done
    inspect_fail=none
    echo 0 >"$work/clock"
    : >"$work/alerts.jsonl"
    sleep() { echo "$(($(cat "$work/clock") + 30))" >"$work/clock"; }
    egress() {
        if [ "$(cat "$work/clock")" -ge 6000 ]; then
            printf '{"text":"egress recovered following Tor restart;"}\n' >"$work/alerts.jsonl"
        fi
    }
    export -f sleep egress
    sed -n '/^started=$(date/,/^stage=host-recovery/{ /^stage=host-recovery/!p; }' "$ROOT/tests/os/tor-heal-guest.sh" >"$work/confirmation-window.sh"
    cat "$work/recovery-verdict.sh" >>"$work/confirmation-window.sh"
    bash -e "$work/confirmation-window.sh"
    [ "$(cat "$work/clock")" -eq 6000 ]
)

restore_case() (
    work="$work/restore-$1-$2"
    data="$work/data"
    mkdir -p "$data" "$work/stack"
    cd "$work/stack"
    printf 'original config\n' >"$work/config.json"
    printf 'changed config\n' >config.json
    printf 'changed state\n' >"$data/state"
    cat >pithead <<'STUB'
#!/usr/bin/env bash
[ "$*" = 'apply -y' ] || exit 23
printf 'apply completed\n'
STUB
    chmod +x pithead
    printf 'omitted-log-prefix\n' >"$work/diagnostic.log"
    head -c 5000 /dev/zero | tr '\0' x >>"$work/diagnostic.log"
    printf '\nretained-log-tail\n' >>"$work/diagnostic.log"
    # shellcheck disable=SC2034 # extracted restore() reads this guest global.
    sink_started=$3
    systemctl() {
        printf 'sink stopped\n' >"$work/sink-stopped"
        return "${sink_stop_rc:-0}"
    }
    docker() {
        printf 'compose command: %s\n' "$*"
        if [ "$*" = 'compose stop tor' ]; then return "$stop_rc"; fi
    }
    stop_rc=$2
    eval "$(sed -n '/^restore() {/,/^}/p' "$ROOT/tests/os/tor-heal-guest.sh")"
    trap restore EXIT
    exit "$1"
)
restore_case 0 0 1 >"$work/restore-success"
grep -q 'Guest restoration exit: 0; original exit: 0' "$work/restore-success"
grep -qx 'changed state' "$work/restore-0-0/data/state"
if restore_case 17 0 0 >"$work/restore-original-failure"; then exit 1; else [ "$?" = 17 ]; fi
grep -q 'Guest restoration exit: 0; original exit: 17' "$work/restore-original-failure"
grep -q 'Guest command log: restore.log' "$work/restore-original-failure"
grep -q 'retained-log-tail' "$work/restore-original-failure"
if grep -q 'omitted-log-prefix' "$work/restore-original-failure"; then exit 1; fi
[ ! -e "$work/restore-17-0/sink-stopped" ]
if restore_case 0 19 1 >"$work/restore-failure"; then exit 1; else [ "$?" = 1 ]; fi
grep -q 'Guest restoration exit: 1; original exit: 0' "$work/restore-failure"
grep -q 'apply completed' "$work/restore-failure"
grep -qx 'changed state' "$work/restore-0-19/data/state"
if restore_case 17 19 1 >"$work/restore-both-failures"; then exit 1; else [ "$?" = 17 ]; fi
grep -q 'Guest restoration exit: 1; original exit: 17' "$work/restore-both-failures"
sink_stop_rc=21
if restore_case 0 0 1 >"$work/restore-sink-failure"; then exit 1; else [ "$?" = 1 ]; fi
grep -q 'Guest restoration exit: 1; original exit: 0' "$work/restore-sink-failure"
unset sink_stop_rc
# Run the actual preamble in a child: failures inside helpers must identify the stage.
sed '/^cd \/data\/pithead/,$d' "$ROOT/tests/os/tor-heal-guest.sh" >"$work/failure-preamble.sh"
cat >>"$work/failure-preamble.sh" <<'STUB'
stage=inside-helper
fail_helper() { false; }
fail_helper
STUB
if bash "$work/failure-preamble.sh" >"$work/failure-stage" 2>&1; then exit 1; fi
grep -q 'Tor heal guest failed at inside-helper' "$work/failure-stage"
# The enabled leg must start from a healthy Tor: the disabled leg ends network-disabled (job 2213).
grep -E '^stage=(observe-disabled|reset-tor|configure-enabled)$' "$ROOT/tests/os/tor-heal-guest.sh" |
    tr '\n' ' ' | grep -qx 'stage=observe-disabled stage=reset-tor stage=configure-enabled '
echo 'tor-heal harness controls PASS'
