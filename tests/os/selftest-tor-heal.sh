#!/usr/bin/env bash
# Pure harness controls: no containers, guests or network service.
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?}}"
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
    jq -e '.tor.auto_heal == false and .notifications.tor == false' config.json >/dev/null
    configure true
    jq -e '.tor.auto_heal == true and (.notifications.webhooks | length == 1)' config.json >/dev/null
)

restore_case() (
    work="$work/restore-$1-$2"
    data="$work/data"
    mkdir -p "$data" "$work/stack"
    cd "$work/stack"
    printf 'original config\n' >"$work/config.json"
    printf 'changed config\n' >config.json
    printf 'original state\n' >"$work/original-state"
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
cmp "$work/restore-0-0/original-state" "$work/restore-0-0/data/state"
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
echo 'tor-heal harness controls PASS'
