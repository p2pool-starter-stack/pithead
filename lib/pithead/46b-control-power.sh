# --- sys-reboot / sys-poweroff: the only two control verbs that stop the machine outright,
# with no update pending and no confirmation of what comes back (#2384) ------------------------
# An appliance operator has no host shell, so a plain reboot or a clean shutdown was previously
# unreachable except by pulling power on a running box — the thing os/KNOWN-ISSUES.md documents as
# what actually corrupts A/B and data state. These two verbs are the round trip: order the same
# `systemctl` action `12-firstboot-wizard.sh` and `16-reset.sh` already issue elsewhere, through the
# SAME approval gate the other disruptive verbs use. The action name only SELECTS between two
# hardcoded orders; no string from the container ever reaches a command line.
#
# Kept out of 48-os-update-verbs.sh on purpose (per the issue): these verbs are not an OS-update
# step, they share none of its staging state, and that file is already at the file-budget ceiling.

# One power verb per drain, like CONTROL_OS_BUDGET (49-control-request-loop.sh) — a reboot or
# poweroff blocks the runner for the rest of the drain by definition, so a compromised container
# queuing a flood of them must not starve every other pending intent.
control_power_gate() { # <cdir> <id> <actor> <action> — rc 0 = proceed (budget consumed)
    if ! is_appliance; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "power control applies only to a Pithead OS appliance — a Compose install has a host shell and does not need this. Nothing was changed."
        return 1
    fi
    if [ "${CONTROL_POWER_BUDGET:-0}" -le 0 ]; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "another power request is already running in this cycle — retry in a moment."
        return 1
    fi
    CONTROL_POWER_BUDGET=$((CONTROL_POWER_BUDGET - 1))
    return 0
}

# sys-reboot: an ordinary reboot, with no update pending. Unlike os-reboot (48-os-update-verbs.sh)
# this is not gated on an installed update waiting — it is the plain lever an operator needs to
# act on a media-config change or a wedged-but-reachable stack (docs/appliance.md).
control_sys_reboot() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_power_gate "$cdir" "$id" "$actor" "sys-reboot" || return 0
    # The result must land BEFORE the order or the page never learns the reboot is real (same
    # ordering os-reboot relies on).
    control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rebooting",ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "sys-reboot" "rebooting"
    ${PITHEAD_REBOOT_CMD:-systemctl reboot} 2>/dev/null || true
}

# sys-poweroff: a clean shutdown. The machine does NOT come back on its own — an operator
# physically at the box presses the power button, the same trip they were already making to move
# or unplug it. That is stated in the dashboard's own confirm copy, not just here.
control_sys_poweroff() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_power_gate "$cdir" "$id" "$actor" "sys-poweroff" || return 0
    control_write_result "$cdir/results" "$id" "$(jq -n '{status:"shutting-down",ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "sys-poweroff" "shutting-down"
    ${PITHEAD_POWEROFF_CMD:-systemctl poweroff} 2>/dev/null || true
}
