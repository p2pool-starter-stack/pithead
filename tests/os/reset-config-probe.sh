#!/usr/bin/env bash
# Test-only guest probe: record the real stop before config-reset can wipe config or reboot.
# An exported function instruments the CLI's Docker command, including RC4's stderr suppression.
set -uo pipefail
umask 077
export PITHEAD_RESET_PROBE_DIR="${PITHEAD_RESET_PROBE_DIR:-/data/pithead}"
cd "$PITHEAD_RESET_PROBE_DIR" || exit 1
rm -f .reset-compose.result .reset-compose.log

docker() {
    if [ "$*" != 'compose down --remove-orphans' ]; then
        command docker "$@"
        return $?
    fi
    local stop_rc config_present=no
    [ ! -f "$PITHEAD_RESET_PROBE_DIR/config.json" ] || config_present=yes
    command docker "$@" >"$PITHEAD_RESET_PROBE_DIR/.reset-compose.log" 2>&1
    stop_rc=$?
    printf 'compose_exit=%s\nconfig_present=%s\n' "$stop_rc" "$config_present" >"$PITHEAD_RESET_PROBE_DIR/.reset-compose.result" || return 1
    cat "$PITHEAD_RESET_PROBE_DIR/.reset-compose.log" >&2
    return "$stop_rc"
}
export -f docker
./pithead config-reset -y
