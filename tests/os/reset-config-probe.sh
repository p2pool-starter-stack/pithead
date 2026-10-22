#!/usr/bin/env bash
set -uo pipefail
umask 077
export PITHEAD_RESET_PROBE_DIR="${PITHEAD_RESET_PROBE_DIR:-/data/pithead}"
cd "$PITHEAD_RESET_PROBE_DIR" || exit 1
rm -f .reset-compose.result .reset-compose.log

docker() {
    case "$*" in
    'compose down --remove-orphans' | ps*label=com.docker.compose.project=* | stop\ * | rm\ * | unpause\ *) ;;
    *)
        command docker "$@"
        return $?
        ;;
    esac
    local stop_rc=0 config_present=no previous=0
    [ ! -f "$PITHEAD_RESET_PROBE_DIR/config.json" ] || config_present=yes
    if [ -f "$PITHEAD_RESET_PROBE_DIR/.reset-compose.result" ]; then
        previous=$(sed -n 's/^compose_exit=//p' "$PITHEAD_RESET_PROBE_DIR/.reset-compose.result")
    fi
    command docker "$@" 2>"$PITHEAD_RESET_PROBE_DIR/.reset-engine-stderr" || stop_rc=$?
    cat "$PITHEAD_RESET_PROBE_DIR/.reset-engine-stderr" >>"$PITHEAD_RESET_PROBE_DIR/.reset-compose.log" || return 1
    cat "$PITHEAD_RESET_PROBE_DIR/.reset-engine-stderr" >&2
    [ "$previous" != 0 ] || previous="$stop_rc"
    printf 'compose_exit=%s\nconfig_present=%s\n' "$previous" "$config_present" >"$PITHEAD_RESET_PROBE_DIR/.reset-compose.result" || return 1
    return "$stop_rc"
}
export -f docker
./pithead config-reset -y
