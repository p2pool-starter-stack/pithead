#!/usr/bin/env bash
# No guest or engine: the probe must expose a suppressed stop failure independently of reset rc.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_RUN_SUITE=1
# shellcheck source=tests/os/phases/reset-config.sh
source "$SCRIPT_DIR/phases/reset-config.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'compose diagnostic exit %s\n' "$STOP_RC" >&2
exit "$STOP_RC"
STUB
cat >"$work/pithead" <<'STUB'
#!/usr/bin/env bash
# Models an old CLI that hides Compose stderr and exits 0 after cleanup.
docker compose down --remove-orphans 2>/dev/null || true
rm -f config.json
printf 'reset completed\n'
STUB
chmod +x "$work/bin/docker" "$work/pithead"
for stop_rc in 0 125; do
    touch "$work/config.json"
    (
        umask 077
        STOP_RC="$stop_rc" PITHEAD_RESET_PROBE_DIR="$work" PATH="$work/bin:$PATH" \
            bash "$SCRIPT_DIR/reset-config-probe.sh" >"$work/reset-output" 2>&1
    )
    for capture in .reset-compose.result .reset-compose.log reset-output; do
        [ "$(stat -c '%a' "$work/$capture")" = 600 ]
    done
    result=$(cat "$work/.reset-compose.result")
    output=$(cat "$work/.reset-compose.log" "$work/reset-output")
    [ "$result" = "$(printf 'compose_exit=%s\nconfig_present=yes' "$stop_rc")" ]
    grep -Fxq "compose diagnostic exit $stop_rc" "$work/.reset-compose.log"
    [ ! -f "$work/config.json" ]
    if [ "$stop_rc" = 0 ]; then
        _reset_config_shutdown_passed "$result" "$output"
    else
        ! _reset_config_shutdown_passed "$result" "$output"
    fi
done
for result in '' unavailable $'compose_exit=0\nconfig_present=no' $'compose_exit=0\nconfig_present=yes\ncompose_exit=0'; do
    ! _reset_config_shutdown_passed "$result" 'reset completed'
done
for warning in 'Stack shutdown failed — continuing with the config wipe.' 'compose down failed (engine not running?) — continuing with the config wipe.'; do
    ! _reset_config_shutdown_passed $'compose_exit=0\nconfig_present=yes' "$warning"
done
for reader_rc in 2 127; do
    (
        grep() { return "$reader_rc"; }
        ! _reset_config_shutdown_passed $'compose_exit=0\nconfig_present=yes' 'reset completed'
    )
done

# An early warning must still fail with enough following text to close a grep -q pipe early.
large_warning=$(
    printf 'Stack shutdown failed\n'
    head -c 65536 /dev/zero | tr '\0' x
)
! _reset_config_shutdown_passed $'compose_exit=0\nconfig_present=yes' "$large_warning"

# Drive leg 0 through capture and verdict; stop at its next unrelated boot-condition gate.
_ssh() {
    case "$*" in
    'podman exec tor cat /var/lib/tor/monero/hostname') printf 'fixture-onion\n' ;;
    'cat > /data/pithead/.reset-config-probe.sh') cmp -s - "$SCRIPT_DIR/reset-config-probe.sh" ;;
    'cat /data/pithead/.reset-compose.result') printf '%s\n' "$fixture_result" ;;
    'cd /data/pithead && test -f .reset-compose.log'*)
        [ "${fixture_read_error:-0}" = 0 ] || return 255
        local probe_command="$*" quoted_work
        printf -v quoted_work '%q' "$work"
        probe_command="${probe_command/cd \/data\/pithead/cd $quoted_work}"
        bash -c "$probe_command"
        ;;
    *) return 1 ;;
    esac
}
_monerod_height() { printf '100\n'; }
_reboot_wait() {
    [ "$1" = 'umask 077; cd /data/pithead && bash .reset-config-probe.sh > .reset-config-output.log 2>&1' ]
}
wait_unit_condition_evaluated() { return 1; }
info() { :; }
ok() { printf 'ok: %s\n' "$*"; }
bad() { printf 'bad: %s\n' "$*"; }
for stop_rc in 0 125; do
    fixture_result=$(printf 'compose_exit=%s\nconfig_present=yes' "$stop_rc")
    fixture_output="compose diagnostic exit $stop_rc"
    printf '%s\n' "$fixture_output" >"$work/.reset-compose.log"
    printf 'reset completed\n' >"$work/.reset-config-output.log"
    if _phase_reset_config >"$work/phase-rows" 2>"$work/phase-diagnostics"; then exit 1; fi
    grep -Fq "$fixture_result" "$work/phase-diagnostics"
    grep -Fq "$fixture_output" "$work/phase-diagnostics"
    if [ "$stop_rc" = 0 ]; then
        grep -Fq 'ok: config-reset Compose shutdown succeeded before the configuration wipe (exit 0)' "$work/phase-rows"
    else
        grep -Fq 'bad: config-reset Compose shutdown failed or was not recorded before the configuration wipe' "$work/phase-rows"
        ! grep -Fq 'ok: config-reset Compose shutdown succeeded' "$work/phase-rows"
    fi
done
fixture_result=$'compose_exit=0\nconfig_present=yes'
for capture_case in missing oversize read-error; do
    fixture_read_error=0
    printf 'compose stopped\n' >"$work/.reset-compose.log"
    case "$capture_case" in
    missing) rm -f "$work/.reset-compose.log" ;;
    oversize) head -c 65537 /dev/zero >"$work/.reset-compose.log" ;;
    read-error) fixture_read_error=1 ;;
    esac
    if _phase_reset_config >"$work/phase-rows" 2>"$work/phase-diagnostics"; then exit 1; fi
    grep -Fq 'bad: config-reset shutdown diagnostics are missing, unreadable or exceed the capture bound' "$work/phase-rows"
    ! grep -Fq 'ok: config-reset Compose shutdown succeeded' "$work/phase-rows"
done
printf 'selftest-reset-config-probe: PASS (clean stop, suppressed failure, missing/invalid receipts, old/new warnings)\n'
