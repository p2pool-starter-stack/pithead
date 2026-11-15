# shellcheck shell=bash
RR_STARTUP_GUEST="${BASH_SOURCE[0]%/*}/../../os/wizard-startup-guest.sh"

rr_startup_cleanup() {
    rx 'set -e
touch .wizard-startup-release
systemctl stop pithead-firstboot.service
rm -f /run/systemd/system/pithead-firstboot.service.d/startup-restore.conf
systemctl daemon-reload
rm -f .wizard-startup-probe.sh .wizard-startup-held .wizard-startup-release'
}

rr_startup_held() {
    rx 'test -e .wizard-startup-held && test ! -e config.json'
}

rr_startup_exited() {
    local state
    state=$(rx 'systemctl show pithead-firstboot.service -p ActiveState -p Result -p ExecMainStatus') || return 1
    grep -qx ActiveState=inactive <<<"$state" &&
        grep -qx Result=success <<<"$state" &&
        grep -qx ExecMainStatus=0 <<<"$state" && rr_wizard_absent
}

rr_startup_ports_free() {
    local listeners
    listeners=$(rx "ss -H -ltn 'sport = :80 or sport = :443'") || return 1
    [ -z "$listeners" ]
}

rr_startup_restore_body() {
    local boot_before
    boot_before=$(rx 'cat /proc/sys/kernel/random/boot_id') || return 1
    lifecycle_mining_step config-reset rx "$IT_PITHEAD config-reset -y" 2>&1 |
        redact >"$OUT_DIR/startup-restore.reset.log" || true
    if ! reset_restore_wait_reboot "$boot_before" 300; then
        it_fail "startup restore returns from config-reset" "new boot unavailable after 300s"
        return 1
    fi
    if ! rx 'set -e; systemctl stop pithead-firstboot.service; docker rm -f pithead-wizard >/dev/null 2>&1 || true; test ! -e config.json' ||
        ! rx 'umask 077; cat > .wizard-startup-probe.sh' --stdin <"$RR_STARTUP_GUEST" ||
        ! rx 'set -e
rm -f .wizard-startup-held .wizard-startup-release
mkdir -p /run/systemd/system/pithead-firstboot.service.d
printf "[Service]\nExecStart=\nExecStart=/bin/bash /data/pithead/.wizard-startup-probe.sh\n" > /run/systemd/system/pithead-firstboot.service.d/startup-restore.conf
systemctl daemon-reload
systemctl start --no-block pithead-firstboot.service' ||
        ! wait_for 60 1 "wizard paused after entry check" rr_startup_held; then
        it_fail "CLI restore starts between the wizard entry check and round opening" "startup pause unavailable"
        return 1
    fi
    it_pass "CLI restore starts between the wizard entry check and round opening"
    if ! lifecycle_mining_step restore rx "PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' $IT_PITHEAD restore -y $(quote_arg "$1")" 2>&1 |
        redact >"$OUT_DIR/startup-restore.restore.log" || ! rx 'test -s config.json && touch .wizard-startup-release'; then
        it_fail "CLI restore lands configuration before the wizard round opens" "restore failed"
        return 1
    fi
    it_pass "CLI restore lands configuration before the wizard round opens"
    if ! wait_for 90 2 "successful firstboot exit" rr_startup_exited; then
        it_fail "startup restore exits firstboot and removes the wizard" "firstboot did not exit successfully within 90s"
        rx 'systemctl show pithead-firstboot.service; journalctl -b -u pithead-firstboot.service --no-pager -n 30' 2>&1 | redact
        return 1
    fi
    it_pass "startup restore exits firstboot and removes the wizard"
    if wait_for 30 2 "released web ports" rr_startup_ports_free; then
        it_pass "startup restore releases HTTP and HTTPS ports before up"
    else
        it_fail "startup restore releases HTTP and HTTPS ports before up" "a listener remains or the census failed"
        return 1
    fi
    if ! pithead up 2>&1 | redact >"$OUT_DIR/startup-restore.up.log"; then
        it_fail "startup restore starts the dashboard stack" "up failed"
        return 1
    fi
    rr_web_ports_owned_by_dashboard "startup restore" || return 1
    if wait_status_ok 600; then
        it_pass "stack healthy after CLI restore during wizard startup"
    else
        it_fail "stack healthy after CLI restore during wizard startup" "status did not recover"
        return 1
    fi
}

rr_restore_during_wizard_startup() {
    local rc=0
    rr_startup_restore_body "$@" || rc=$?
    if ! rr_startup_cleanup; then
        it_fail "startup restore removes its test service override" "cleanup failed"
        return 1
    fi
    return "$rc"
}
