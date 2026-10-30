#!/usr/bin/env bash

power_verdict() { # <result-json> <status-string> — true if the result names exactly this status
    printf '%s' "$1" | jq -e --arg s "$2" '.status == $s' >/dev/null
}

power_shutdown_verdict() {
    printf '%s' "$1" | grep -Eq 'pithead-boot.service: Deactivated successfully|Stopped Pithead stack at boot'
}

phase_provision_power_regressions() {
    local before result journal mtries=0 miner_back=0 code
    before=$(_boot_id) || before=""
    [ -n "$before" ] || {
        bad "could not read the boot id before the dashboard-ordered reboot"
        return
    }
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
    journal=$(_ssh "journalctl -b -1 -u pithead-boot.service --no-pager -o cat" 2>/dev/null) || {
        bad "could not read the previous boot's stack shutdown journal"
        return
    }
    if power_shutdown_verdict "$journal"; then
        ok "the prior boot's journal records an orderly stop of the stack unit"
    else
        bad "the prior boot's journal does not record an orderly stop of the stack unit"
        return
    fi
    journal=$(_ssh "dmesg" 2>/dev/null) || {
        bad "could not read shutdown recovery evidence after the power-button restart"
        return
    }
    if printf '%s' "$journal" | grep -qi 'recovering journal\|Superblock has_journal'; then
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
    power_shutdown_verdict 'pithead-boot.service: Deactivated successfully.' || f=$((f + 1))
    power_shutdown_verdict 'Stopped Pithead stack at boot — render, up, health-gated A/B commit.' || f=$((f + 1))
    power_shutdown_verdict 'Starting Pithead stack at boot.' && f=$((f + 1))
    power_shutdown_verdict '' && f=$((f + 1))
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
