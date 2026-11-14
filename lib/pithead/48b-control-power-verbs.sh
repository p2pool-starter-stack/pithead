control_power_inflight_result() { # <control-dir> — rc 0 = an OS check or power result is still in flight
    local f window up
    window=5
    up=$(awk '{print int($1 / 60)}' /proc/uptime 2>/dev/null) || up=""
    [[ "$up" =~ ^[0-9]+$ ]] && [ "$up" -lt "$window" ] && window=$((up > 0 ? up : 1))
    while IFS= read -r f; do
        case "$(jq -r '.status // ""' "$f" 2>/dev/null || true)" in
        checking | rebooting | shutting-down) return 0 ;;
        esac
    done < <(find "$1/results" -maxdepth 1 -type f -name '*.json' -mmin -"$window" 2>/dev/null)
    return 1
}

control_power_refusal() { # <control-dir> — echoes the reason a power verb must not run now; empty = clear
    local cdir="$1" running to step
    step=$(jq -r '.step // ""' "$cdir/results/os-update-state.json" 2>/dev/null) || step=""
    if [ -f "$(os_update_inflight_file)" ] && ! jq -e . "$cdir/results/os-update-state.json" >/dev/null 2>&1; then
        printf '%s' "the OS update state is unreadable while an update is armed — a power action now could interrupt it. Check for updates again, then try again."
        return 0
    fi
    case "$step" in
    downloading | installing | verifying | reboot-pending)
        printf '%s' "an appliance OS update is in progress ($step) — a power action now could interrupt it. Wait for it to finish, then try again."
        return 0
        ;;
    esac
    if control_power_inflight_result "$cdir"; then
        printf '%s' "an OS check or a power action is already in flight — retry in a few minutes."
        return 0
    fi
    if [ -f "$(os_update_inflight_file)" ]; then
        running=$(os_running_version)
        to=$(jq -r '.to // ""' "$(os_update_inflight_file)" 2>/dev/null) || to=""
        if [ -n "$to" ] && [ "$running" = "$to" ]; then
            printf '%s' "this machine is already running v$to and the installed update is still being verified — a power action now would take the machine back to the previous version. Leave it running until the verification finishes."
            return 0
        fi
    fi
    return 0
}

control_power_stop_stack() { # <action>
    [ -f "$ENV_FILE" ] || return 0
    log "Stopping the stack before $1..."
    timeout "${CONTROL_POWER_STOP_TIMEOUT_S:-300}" docker compose stop >/dev/null 2>&1 && log "Stack stopped before $1."
}

control_power() { # <claimed-file> <id> <actor> <control-dir> <action>
    local file="$1" id="$2" actor="$3" cdir="$4" action="$5" word=SHUTDOWN
    [ "$action" != power-reboot ] || word=REBOOT
    if [ "$(jq -r 'keys | sort == ["action","actor","confirm","id"]' "$file")" != true ] ||
        [ "$(jq -r '.confirm // ""' "$file")" != "$word" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "$action" rejected "type $word to confirm — nothing was changed."
        return 0
    fi
    control_os_gate "$cdir" "$id" "$actor" "$action" CONTROL_POWER_BUDGET || return 0
    local rc=0
    control_power_run "$cdir" "$id" "$actor" "$action" || rc=$?
    case "$rc" in
    0) ;;
    3) CONTROL_POWER_ORDERED=1 ;;
    *) control_os_refuse "$cdir" "$id" "$actor" "$action" rejected "host mutation lock unavailable — nothing was changed." ;;
    esac
}

control_power_run() ( # <control-dir> <id> <actor> <action> — isolate the lock's exit-on-contention path
    local cdir="$1" id="$2" actor="$3" action="$4" target=poweroff result=shutting-down busy stamp="$1/power-cooldown" last=0 now
    [ "$action" != power-reboot ] || { target=reboot result=rebooting; }
    command -v flock >/dev/null || return 1
    PITHEAD_LOCK_TIMEOUT=0 mutation_lock_acquire "$action" || return 1
    [ "${_PITHEAD_LOCK_OWNED:-0}" = 1 ] || return 1
    busy=$(control_power_refusal "$cdir")
    if [ -n "$busy" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "$action" rejected "$busy"
        return 0
    fi
    now=$(date +%s)
    [ ! -L "$stamp" ] || rm -f "$stamp"
    [ ! -f "$stamp" ] || read -r last <"$stamp" || last=0
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [ "$last" -le "$now" ] && [ $((now - last)) -lt "${CONTROL_POWER_COOLDOWN_S:-300}" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "$action" rejected "a power action ran less than $((${CONTROL_POWER_COOLDOWN_S:-300} / 60)) minutes ago — retry in a few minutes."
        return 0
    fi
    if ! printf '%s\n' "$now" >"$stamp"; then
        control_os_refuse "$cdir" "$id" "$actor" "$action" failed "the power cooldown record could not be written — nothing was changed."
        return 0
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg s "$result" '{status:$s,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "$action" "$result"
    if ! control_power_stop_stack "$action"; then
        control_os_refuse "$cdir" "$id" "$actor" "$action" failed "the stack did not stop cleanly — the machine was not powered off and some services may be stopped; check the host journal, then restart the stack from the dashboard."
        return 0
    fi
    if ! systemctl "$target" >/dev/null 2>&1; then
        control_os_refuse "$cdir" "$id" "$actor" "$action" failed "systemctl $target failed — the machine is still running with its stack stopped; restart the stack from the dashboard."
        return 0
    fi
    return 3
)
