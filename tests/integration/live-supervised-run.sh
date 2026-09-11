#!/usr/bin/env bash
# Runs one destructive gate as a host-owned transaction and publishes its terminal status.
set -uo pipefail
result="$1"
heartbeat="$2"
max_seconds="$3"
shift 3
[[ "$max_seconds" =~ ^[1-9][0-9]*$ ]] || exit 2
publish() { printf '%s\n' "$1" >"$result.tmp" && mv "$result.tmp" "$result"; }
stop_child() {
    kill -TERM -- "-$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
}
stop_watchdog() {
    [ "$watchdog" -gt 0 ] 2>/dev/null || return 0
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
}
setsid "$@" &
child=$!
watchdog=0
finished=0
cleanup() {
    local rc=$?
    [ "$finished" = 1 ] || {
        stop_watchdog
        stop_child
        publish "$rc"
    }
}
trap cleanup EXIT
started="$(date +%s)"
timeout_marker="$result.timeout"
rm -f "$timeout_marker"
(
    while kill -0 "$child" 2>/dev/null; do
        now="$(date +%s)"
        heartbeat_time="$(stat -c %Y "$heartbeat" 2>/dev/null || stat -f %m "$heartbeat" 2>/dev/null || echo 0)"
        if [ $((now - heartbeat_time)) -gt 30 ] || [ $((now - started)) -ge "$max_seconds" ]; then
            : >"$timeout_marker"
            kill -TERM -- "-$child" 2>/dev/null || true
            exit
        fi
        sleep 5
    done
) &
watchdog=$!
wait "$child"
rc=$?
stop_watchdog
[ ! -f "$timeout_marker" ] || rc=124
publish "$rc"
finished=1
exit "$rc"
