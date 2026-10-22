#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?}}"
work=$(mktemp -d "${TMPDIR:?}/tor-recovery-refusal-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
echo '== guest healthy Tor recovery refusal controls =='
mkdir -p "$work/stack/tor" "$work/stack/control" "$work/bin"
cp "$ROOT/pithead" "$work/stack/pithead"
printf 'DEPLOYMENT_COMPLETED=true\nTOR_DATA_DIR=%s\nCONTROL_DIR=%s\n' \
    "$work/stack/tor" "$work/stack/control" >"$work/stack/.env"
printf 'CircuitBuildTimeBin 1 2\n' >"$work/stack/tor/state"
cat >"$work/bin/sudo" <<'STUB'
#!/usr/bin/env bash
if [ "${SUDO_STATE_READ_FAIL:-0}" = 1 ] && [ "$1" = cat ]; then exit 2; fi
exec "$@"
STUB
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
*'.Config.Labels'*) printf 'tor\n' ;;
*'.Source'*) printf '%s\n' "$TOR_FIXTURE_DATA" ;;
*'.Destination'*) printf 'x\n' ;;
*) echo 'unexpected Docker command in read-only fixture' >&2; exit 99 ;;
esac
STUB
cat >"$work/bin/awk" <<'STUB'
#!/usr/bin/env bash
[ "${STATE_PARSE_ERROR:-0}" = 0 ] || exit 2
exec /usr/bin/awk "$@"
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" TOR_FIXTURE_DATA="$work/stack/tor"
sed "s|^cd /data/pithead$|cd '$work/stack'|" \
    "$ROOT/tests/os/tor-recovery-refusal-guest.sh" >"$work/guest.sh"
bash "$work/guest.sh" >"$work/pass" 2>"$work/errors" || {
    cat "$work/errors" >&2
    exit 1
}
grep -Fq 'PASS: guest healthy Tor recovery check' "$work/pass"
[ ! -s "$work/errors" ]
sed '/local _PITHEAD_TOR_RECOVERY_CLI=1/d' "$ROOT/pithead" >"$work/stack/pithead"
if bash "$work/guest.sh" >"$work/pre-fix" 2>&1; then
    echo 'FAIL: guest assertion accepted the pre-fix CLI' >&2
    exit 1
fi
grep -Fq 'unexpected-abort advice' "$work/pre-fix"
cp "$ROOT/pithead" "$work/stack/pithead"
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$work/stack/tor/state"
if bash "$work/guest.sh" >"$work/saturated" 2>&1; then exit 1; fi
grep -Fq 'healthy-refusal precondition is not established' "$work/saturated"
cp "$ROOT/pithead" "$work/stack/pithead"
printf 'CircuitBuildTimeBin 1 2\n' >"$work/stack/tor/state"
for failure in read parse; do
    if [ "$failure" = read ]; then
        export SUDO_STATE_READ_FAIL=1
    else
        export STATE_PARSE_ERROR=1
    fi
    if bash "$work/guest.sh" >"$work/$failure-error" 2>&1; then exit 1; fi
    if [ "$failure" = read ]; then
        grep -Fq 'live Tor state could not be read' "$work/$failure-error"
    else
        grep -Fq 'Tor history classification failed' "$work/$failure-error"
    fi
    unset SUDO_STATE_READ_FAIL STATE_PARSE_ERROR
done
if TOR_FIXTURE_DATA="$work/other-mount" bash "$work/guest.sh" >"$work/mount-error" 2>&1; then exit 1; fi
grep -Fq 'live Tor data mount could not be verified' "$work/mount-error"
rm "$work/stack/tor/state"
if bash "$work/guest.sh" >"$work/missing-state" 2>&1; then exit 1; fi

eval "$(sed -n '/^_phase_provision_initial_body() {/,/    local onion_prefix/p' "$ROOT/tests/os/phases/provision-initial.sh" | sed '$d')
}"
# shellcheck disable=SC2034 # The extracted provisioning function reads these globals.
SERIAL="$work/serial" SCRIPT_DIR="$ROOT/tests/os" jar="$work/jar" ip=fixture
printf 'pit-FIXTUR\n' >"$SERIAL"
info() { :; }
ok() { printf '%s\n' "$*" >>"$work/rows"; }
bad() { printf '%s\n' "$*" >>"$work/failed-rows"; }
_build_image() { echo fixture; }
_vm_boot_disk() { :; }
_wait_ssh() { :; }
_wait_setup_page() { :; }
phase_wizard_redirect() { :; }
stage_dashboard_exposure_addresses() { :; }
provision_node_preflight() { :; }
provision_setup_failure_recovery() { :; }
provision_browser_submit() { echo 200; }
wizard_miner_connection_card_valid() { :; }
provisioning_settled() { printf 'settled\n' >"$work/settled"; }
provisioning_setup_failed() { return 1; }
provisioning_state() { echo settled; }
curl() {
    case "$*" in
    *'/auth'*) printf 'wizard_session\n' >"$jar" ;;
    *'/api/handoff'*) printf '{"password":"%032d"}\n' 0 ;;
    *'/handoff-ack'*) echo 200 ;;
    *) echo 301 ;;
    esac
}
eval "$(sed -n '/^_ssh() {/,/^}/p' "$ROOT/tests/os/lib/core.sh")"
# shellcheck disable=SC2034
SSH_ERR="$work/ssh-error" KEY=fixture SSH_TIMEOUT=45
ssh() {
    case "$*" in
    *'podman ps'*) echo 'dashboard caddy' ;;
    *'timeout 40 bash -s')
        [ "$SSH_TIMEOUT" = 45 ] && [ -s "$work/settled" ] || return 91
        cat >"$work/streamed-script"
        printf '%s\n' "$guest_error" >&2
        if [ "${remove_capture:-0}" = 1 ]; then rm -f "$SSH_ERR"; fi
        return "$guest_rc"
        ;;
    *) printf 'overwritten by later guest call\n' >&2 ;;
    esac
}
timeout() {
    [ "$1" = "$SSH_TIMEOUT" ] || return 92
    shift
    "$@"
}
run_provision_control() {
    rm -f "$work/rows" "$work/failed-rows" "$work/settled" "$work/streamed-script"
    _phase_provision_initial_body
    cmp "$ROOT/tests/os/tor-recovery-refusal-guest.sh" "$work/streamed-script"
    _ssh true
    grep -Fxq 'overwritten by later guest call' "$SSH_ERR"
    if [ "$guest_rc" = 0 ]; then
        grep -Fq 'guest healthy Tor recovery refusal exits 1' "$work/rows"
        [ ! -e "$work/failed-rows" ]
    else
        grep -Fq 'guest healthy Tor recovery refusal proof failed' "$work/failed-rows"
        grep -Fq "ssh_exit=$guest_rc reason=$expected_reason" "$work/failed-rows"
        if grep -Fq 'guest healthy Tor recovery refusal exits 1' "$work/rows"; then exit 1; fi
        if grep -Eq 'SECRET_SENTINEL|fixture.invalid|/private-fixture' "$work/failed-rows"; then exit 1; fi
        [ "$(wc -c <"$work/failed-rows")" -lt 256 ]
    fi
}
guest_rc=0 guest_error=SECRET_SENTINEL expected_reason=unused
run_provision_control
for control in \
    'mount-error|mount_unverified' \
    'missing-state|state_unavailable' \
    'read-error|state_read_failed' \
    'saturated|saturated_precondition' \
    'parse-error|state_classification_failed' \
    'pre-fix|unexpected_abort_or_unreadable_stderr'; do
    guest_rc=1 guest_error=$(cat "$work/${control%|*}") expected_reason=${control#*|}
    run_provision_control
done
for command_rc in 0 2 124 137; do
    guest_rc=1 guest_error="FAIL: healthy Tor recovery check exits $command_rc, expected 1 (#3262)" expected_reason=command_exit
    run_provision_control
    grep -Fq "command_exit=$command_rc" "$work/failed-rows"
done
guest_rc=1 guest_error='FAIL: healthy Tor recovery check lacks the unsaturated-history warning on stderr (#3262)' expected_reason=missing_warning
run_provision_control
for guest_rc in 17 124 137 255; do
    case "$guest_rc" in
    124) expected_reason=ssh_or_guest_deadline ;;
    137) expected_reason=ssh_or_guest_killed ;;
    255) expected_reason=ssh_transport ;;
    *) expected_reason=diagnostic_unavailable ;;
    esac
    guest_error='SECRET_SENTINEL fixture.invalid /private-fixture'
    run_provision_control
done
guest_rc=1 expected_reason=state_read_failed
guest_error='SECRET_SENTINEL fixture.invalid /private-fixture
FAIL: live Tor state could not be read (#3262)'
run_provision_control
remove_capture=1 expected_reason=diagnostic_unavailable
run_provision_control
unset remove_capture
guest_error='FAIL: healthy Tor recovery check exits 999, expected 1 (#3262)'
run_provision_control
guest_rc=1 expected_reason=diagnostic_unavailable
guest_error="$(printf '%09000d' 0)SECRET_SENTINEL
FAIL: live Tor state could not be read (#3262)"
run_provision_control
grep -Fq 'clipped=yes' "$work/failed-rows"
if bash "$ROOT/tests/os/tor-recovery-refusal-diagnostic.sh" 1 "$work/does-not-exist" >"$work/unavailable"; then exit 1; fi
if grep -Eq 'SECRET_SENTINEL|does-not-exist' "$work/unavailable"; then exit 1; fi
echo 'guest healthy Tor recovery refusal selftest PASS'
