#!/usr/bin/env bash
set -uo pipefail

mode="$1" state="$2"
exec 9>"$state.lock"
flock -x 9 || exit 1

group_alive() {
    local processes
    processes="$(ps -axo pgid=,stat=)" || return 2
    awk -v group="$pid" '$1 == group && $2 !~ /^Z/ { alive=1 } END { exit !alive }' <<<"$processes"
}

case "$mode" in
run)
    record="$(cat "$state")" || exit 1
    [ "$record" = intent ] || exit 143
    pid=$$
    [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pid" ] || exit 1
    start="$(awk '{print $22}' "/proc/$pid/stat")" || exit 1
    printf 'running %s %s\n' "$pid" "$start" >"$state" || exit 1
    flock -u 9 || exit 1
    exec 9>&-
    bash -c "$3"
    ;;
drain)
    if [ -e "$state" ]; then
        record="$(cat "$state")" || exit 1
    else
        record=intent
    fi
    if [[ "$record" =~ ^running\ ([0-9]+)\ ([0-9]+)$ ]]; then
        pid="${BASH_REMATCH[1]}" start="${BASH_REMATCH[2]}"
        [ "$pid" -gt 1 ] && [ "$start" -gt 0 ] || exit 1
        if [ -r "/proc/$pid/stat" ]; then
            [ "$(awk '{print $22}' "/proc/$pid/stat")" = "$start" ] || exit 1
            [ "$(awk '/^Uid:/ {print $2}' "/proc/$pid/status")" = "$(id -u)" ] || exit 1
            [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pid" ] || exit 1
        fi
        for sig in TERM KILL; do
            kill -"$sig" -- "-$pid" 2>/dev/null || true
            sudo -n kill -"$sig" -- "-$pid" 2>/dev/null || true
            deadline=$((SECONDS + 5))
            while :; do
                group_alive
                rc=$?
                [ "$rc" -eq 1 ] && break
                [ "$rc" -eq 0 ] || exit 1
                [ "$SECONDS" -lt "$deadline" ] || break
                sleep .1
            done
            [ "$rc" -eq 1 ] && break
        done
        [ "$rc" -eq 1 ] || exit 1
    else
        case "$record" in intent | stopped) ;; *) exit 1 ;; esac
    fi
    printf 'stopped\n' >"$state"
    ;;
*) exit 1 ;;
esac
