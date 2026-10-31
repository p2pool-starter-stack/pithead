# shellcheck shell=bash
_lan_crash_snippet() {
    cat <<'CAPTURE'
printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! timeout --kill-after=1 1 docker inspect -f 'node={{.State.Running}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} starts={{.RestartCount}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' "$1" 2>/dev/null; then
    echo node=unavailable
fi
for unit in pithead-lan.timer pithead-lan-check.service; do
    echo "unit=$unit"
    timeout --kill-after=1 1 systemctl show -p ActiveState,SubState,Result,ExecMainStatus,ExecMainStartTimestampMonotonic,ExecMainExitTimestampMonotonic "$unit" 2>/dev/null || echo unit=unavailable
done
if test -s data/lan-guard/enforced; then echo marker=present; else echo marker=absent; fi
CAPTURE
}

_lan_crash_capture() {
    local node="$1" stage="$2" observed="$3" deadline="$4" remaining out kept transport LC_ALL=C
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || return 0
    [ "$remaining" -le 3 ] || remaining=3
    case "$observed" in true | false | running | unknown | [0-9] | [0-9][0-9] | [0-9][0-9][0-9]) ;; *) observed=unavailable ;; esac
    transport="$(declare -f rx quote_arg)
$(declare -p IT_MODE IT_REMOTE_DIR IT_SSH_OPTS IT_SSH_DEST 2>/dev/null || true)
rx \"\$1\""
    out=$(
        set -o pipefail
        timeout --kill-after=1 "$remaining" bash -c "$transport" _ "timeout --kill-after=1 $remaining bash -c $(quote_arg "$(_lan_crash_snippet)") _ $(quote_arg "$node")" 2>/dev/null | head -c 8193
    ) || out=""
    if [ "${#out}" -gt 8192 ]; then out=""; fi
    kept=$(printf '%s\n' "$out" | LC_ALL=C grep -E '^(captured_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z|node=(true|false) exit=[0-9]{1,3} oom=(true|false) starts=[0-9]{1,9} started=[0-9TZ:.+-]{1,40} finished=[0-9TZ:.+-]{1,40}|node=unavailable|unit=(pithead-lan.timer|pithead-lan-check.service|unavailable)|ActiveState=(active|activating|deactivating|inactive|failed|reloading)|SubState=(dead|running|waiting|elapsed|exited|start|start-pre|start-post|stop|stop-sigterm|stop-sigkill|failed|auto-restart)|Result=(success|resources|timeout|exit-code|signal|core-dump|watchdog|start-limit-hit|protocol|condition|assert|dependency)|ExecMainStatus=[0-9]{1,3}|(ExecMainStartTimestampMonotonic|ExecMainExitTimestampMonotonic)=[0-9]{1,20}|marker=(present|absent))$' | head -n 32) || true
    {
        printf 'sample_utc=%s stage=%s observed=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" "$observed"
        if [ -n "$kept" ]; then
            printf '%s\n' "$kept"
            if [ "$kept" != "$out" ]; then echo capture=filtered; fi
        else
            echo capture=unavailable
        fi
    } 2>/dev/null >>"$LAN_CRASH_EVIDENCE" || it_fail "LAN crash evidence retained" "diagnostic write unavailable; controls continue"
}
