control_power_gate() { # <cdir> <id> <actor> <action> — rc 0 = proceed (budget + cooldown claimed)
    if ! is_appliance; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "power control applies only to a Pithead OS appliance — a Compose install has a host shell and does not need this. Nothing was changed."
        return 1
    fi
    if [ "${CONTROL_POWER_BUDGET:-0}" -le 0 ]; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "another power request is already running in this cycle — retry in a moment."
        return 1
    fi
    local stamp="$1/.power-stamp.$4"
    if [ -n "$(find "$stamp" \( -mmin -5 -o -newermt now \) 2>/dev/null)" ]; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "the same power order ran less than five minutes ago — retry in a few minutes."
        return 1
    fi
    if ! touch "$stamp" 2>/dev/null; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "could not record the power-request cooldown — nothing was changed."
        return 1
    fi
    CONTROL_POWER_BUDGET=$((CONTROL_POWER_BUDGET - 1))
    return 0
}

control_sys_reboot() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_power_gate "$cdir" "$id" "$actor" "sys-reboot" || return 0
    control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rebooting",ts:(now|floor)}')" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "sys-reboot" "rebooting" || return 0
    ${PITHEAD_REBOOT_CMD:-systemctl reboot} 2>/dev/null || true
}

control_sys_poweroff() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_power_gate "$cdir" "$id" "$actor" "sys-poweroff" || return 0
    control_write_result "$cdir/results" "$id" "$(jq -n '{status:"shutting-down",ts:(now|floor)}')" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "sys-poweroff" "shutting-down" || return 0
    ${PITHEAD_POWEROFF_CMD:-systemctl poweroff} 2>/dev/null || true
}
