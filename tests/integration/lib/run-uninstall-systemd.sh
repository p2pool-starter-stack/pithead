# shellcheck shell=bash
arm_uninstall_systemd_state() {
    if rx '
        set -eu
        sudo systemctl cat pithead-egress.service pithead-lan-check.service >/dev/null
        sudo systemctl stop pithead-lan.timer pithead-lan-check.service
        sudo systemctl start pithead-egress.service
        [ "$(systemctl show -p ActiveState --value pithead-egress.service)" = active ]
        [ "$(systemctl show -p SubState --value pithead-egress.service)" = exited ]
        override=/run/systemd/system/pithead-lan-check.service.d/pithead-itest-failure.conf
        test ! -e "$override"
        cleanup() {
            sudo rm -f "$override" && sudo systemctl daemon-reload
        }
        trap cleanup EXIT
        sudo mkdir -p "${override%/*}"
        printf "[Service]\nExecStart=\nExecStart=/usr/bin/false\n" | sudo tee "$override" >/dev/null
        sudo systemctl daemon-reload
        if sudo systemctl start pithead-lan-check.service; then exit 1; fi
        [ "$(systemctl show -p ActiveState --value pithead-lan-check.service)" = failed ]
        cleanup
        trap - EXIT
    ' >/dev/null 2>&1; then
        it_pass "uninstall starts with active-exited egress and failed LAN-check services"
    else
        it_fail "uninstall starts with active-exited egress and failed LAN-check services" "could not arm the systemd regression fixture"
        return 1
    fi
}

verify_uninstall_systemd_state() {
    local inventory attempt
    for ((attempt = 0; attempt < 5; attempt++)); do
        if ! inventory="$(rx 'systemctl list-units --all --plain --no-legend pithead-control.path pithead-control.service pithead-egress.service pithead-egress.timer pithead-egress-check.service pithead-lan-guard.service pithead-lan-hold.service pithead-lan.timer pithead-lan-check.service')"; then
            it_fail "uninstall removes every Pithead systemd manager record" "systemctl inventory could not be read"
            return 1
        fi
        if [ -z "$inventory" ]; then
            it_pass "uninstall removes every Pithead systemd manager record"
            return 0
        fi
        sleep 1
    done
    it_fail "uninstall removes every Pithead systemd manager record" "active, failed or loaded records remain after removal"
    return 1
}
