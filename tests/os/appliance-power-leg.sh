#!/usr/bin/env bash
# Dashboard-driven reboot and poweroff over the control channel (#2384). Sourced by
# tests/os/run.sh; --self-test covers the pure verdict helper without a guest.
#
# The reboot half proves the SAME bar tests/os/phases/provision-reboot.sh already proves for a raw
# ssh reboot — an unaided return — but ordered through the dashboard's sys-reboot verb instead, so
# the assertion is that the control channel is what triggered it, not just that the machine came
# back. The poweroff half is the genuinely new claim: the guest reaches `shut off` ON ITS OWN
# (never `virsh destroy`d), and coming back requires something outside the guest to start it again
# — `virsh start` standing in for a hand at the physical power button, which is the one half of
# this round trip a VM cannot itself exercise (recorded in os/KNOWN-ISSUES.md and the manual
# release checklist's M17).

power_verdict() { # <result-json> <status-string> — true if the result names exactly this status
    printf '%s' "$1" | jq -e --arg s "$2" '.status == $s' >/dev/null
}

phase_provision_power_regressions() {
    local before result mtries=0 miner_back=0 code
    # --- sys-reboot: the dashboard button, not a raw ssh reboot -------------------------------
    before=$(_boot_id) || info "could not read the boot id before the dashboard-ordered reboot"
    # The polled result RACES the reboot it reports: control_sys_reboot writes it before issuing
    # `systemctl reboot`, but that order can tear the guest's network down before the poll's next
    # round trip completes, so "no result" here is expected, not a verdict — exactly the race
    # tests/os/phases/update-dashboard.sh's own os-reboot leg already discards ("the machine goes
    # away mid-poll; no id, no reboot"). Only an in-band REJECTED status is trustworthy; the real
    # proof that the order was accepted AND completed is the new boot below.
    result=$(dashboard_control_request power '{"action":"reboot"}' 30) || true
    if power_verdict "$result" rejected; then
        bad "sys-reboot was refused through the control channel ($(control_result_payload "$result"))"
        return
    fi
    if [ -n "$before" ] && _wait_new_boot "$before" 300; then
        ok "sys-reboot was ordered through the dashboard control channel and the guest returned unaided"
    else
        # shellcheck disable=SC2154 # $ip is shared through the assembled runner scope.
        bad "the guest never came back after a dashboard-ordered reboot ($(_ssh_unreachable_reason "$ip"))"
        return
    fi
    # Re-acquire the lease rather than assuming it: a guest that took a DIFFERENT address would
    # otherwise make every probe below fail as "never came back", which is the misreport
    # _ssh_unreachable_reason exists to stop (tests/os/lib/core.sh). Sets the shared `ip`.
    _wait_dhcp_ip 120 || {
        bad "no DHCP lease after the dashboard-ordered reboot — every probe below would red for that, not for the product"
        return
    }
    _wait_ssh 120 || true
    code=""
    local tries=0 answered=0
    while [ "$tries" -lt 36 ]; do
        # shellcheck disable=SC2154 # $ip is set by the phase's own DHCP wait, ambient scope.
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
        case "$code" in
        2?? | 3?? | 401 | 403)
            answered=1
            break
            ;;
        esac
        sleep 5
        tries=$((tries + 1))
    done
    if [ "$answered" -eq 1 ]; then
        ok "the dashboard answers again after the dashboard-ordered reboot (HTTP $code)"
    else
        bad "the dashboard never answered after the dashboard-ordered reboot (last: $code)"
        return
    fi

    # --- sys-poweroff: same race as the reboot above (podman/caddy die before the poll can read
    # the already-written result), so the result is fire-and-forget too; `_poweroff_wait` is the
    # proof. The guest must reach shut off ON ITS OWN, then only comes back on a hand at the power
    # button (simulated here as `virsh start`). --------------------------------------------------
    result=$(dashboard_control_request power '{"action":"poweroff"}' 30) || true
    if power_verdict "$result" rejected; then
        bad "sys-poweroff was refused through the control channel ($(control_result_payload "$result"))"
        return
    fi
    if _poweroff_wait 180; then
        ok "sys-poweroff was ordered through the dashboard control channel and the guest reached 'shut off' on its own"
    else
        bad "the guest never reached 'shut off' after the dashboard-ordered poweroff"
        return
    fi
    # A dirty ext4 fsck-on-mount message would show up in THIS boot's own dmesg/journal, since a
    # journal-recovered filesystem logs the recovery on the boot that mounts it.
    virsh start "$VM" >/dev/null 2>&1 || {
        bad "could not start the guest again after the dashboard-ordered poweroff"
        return
    }
    _wait_dhcp_ip 180 || {
        bad "no DHCP lease after the power-button restart — every probe below would red for that, not for the product"
        return
    }
    if _wait_ssh 300; then
        ok "the guest boots back up once started — the physical-power-button half of the round trip"
    else
        bad "the guest never came back up after being started following the poweroff ($(_ssh_unreachable_reason "$ip"))"
        return
    fi
    if _ssh "dmesg 2>/dev/null | grep -qi 'recovering journal\|Superblock has_journal'" 2>/dev/null; then
        bad "this boot's dmesg shows a journal recovery — the previous shutdown was not clean"
    else
        ok "no journal-recovery message after the poweroff/power-button round trip — an orderly stop"
    fi
    while [ "$mtries" -lt 24 ]; do
        if _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null" 2>/dev/null; then
            miner_back=1
            break
        fi
        sleep 10
        mtries=$((mtries + 1))
    done
    if [ "$miner_back" -eq 1 ]; then
        ok "mining resumed after the poweroff/power-button round trip"
    else
        bad "mining did not resume after the poweroff/power-button round trip"
    fi
}

_power_self_test() {
    local f=0
    power_verdict '{"status":"rejected"}' rejected || f=$((f + 1))
    power_verdict '{"status":"rebooting"}' rejected && f=$((f + 1))
    power_verdict '{"status":"shutting-down"}' rejected && f=$((f + 1))
    power_verdict '' rejected && f=$((f + 1))
    [ "$f" -eq 0 ] || {
        printf 'appliance-power-leg self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'appliance-power-leg self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    _power_self_test
fi
