control_tor_recover() { # <control-dir> <id> <actor> [action]
    local cdir="$1" id="$2" actor="$3" action="${4:-tor-recover}" output status detail
    if output=$( (tor_recover apply) 2>&1); then
        status=applied
        detail=""
    else
        status=failed
        detail=$(printf '%s\n' "$output" | bundle_redact_log | tail -c 4096)
        [ -n "$detail" ] || detail="Tor recovery refused or failed host verification"
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg status "$status" --arg action "$action" --arg error "$detail" '{status:$status,action:$action,error:$error,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "$action" "$status"
}

CONTROL_TOR_RESET_COOLDOWN_S=1800

control_tor_reset() { # <control-dir> <id> <actor>
    local cdir="$1" id="$2" actor="$3" stamp="$1/tor-reset-at" last=0 now error=""
    now=$(date +%s)
    if [ -L "$stamp" ]; then
        last=invalid
    elif [ -f "$stamp" ]; then
        read -r last <"$stamp" || last=invalid
    fi
    if ! [[ "$last" =~ ^[0-9]+$ ]]; then
        error="the Reset Tor state record is invalid, so the reset was not attempted"
    elif [ "$last" -le "$now" ] && [ $((now - last)) -lt "$CONTROL_TOR_RESET_COOLDOWN_S" ]; then
        error="Reset Tor state was already requested $(((now - last) / 60)) minutes ago — wait $(((CONTROL_TOR_RESET_COOLDOWN_S - (now - last) + 59) / 60)) more minutes before asking again"
    fi
    if [ -n "$error" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$error" '{status:"rejected",action:"tor-reset",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" tor-reset rejected
    elif ! printf '%s\n' "$now" >"$stamp"; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"failed",action:"tor-reset",error:"the Reset Tor state record could not be written",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" tor-reset failed
    else
        control_tor_recover "$cdir" "$id" "$actor" tor-reset
    fi
}
