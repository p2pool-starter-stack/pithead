# shellcheck shell=bash
# shellcheck disable=SC2154 # guest address shared by the suite runner
: "${OS_RUN_SUITE:?source via the suite runner}"
phase_update_power_leg() {
    info "leg 4b — host power-reboot and power-shutdown on the committed, provisioned guest (#4084)"
    if [ "${LEG4_PITHEAD_BOOT_PROVED:-0}" != "1" ]; then
        it_skip_leg "host power verbs (#4084)" \
            "leg 4 did not reach a committed, provisioned guest on this run, so there is no control runner to drive" missing
        return
    fi
    local cdir=/data/pithead/data/control before out id deadline audit
    local rid_bad="4084aaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" rid_reboot="4084bbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" rid_off="4084cccc-cccc-4ccc-8ccc-cccccccccccc"
    local plant="for i in \$(seq 90); do [ -f $cdir/results/\$id.json ] && break; sleep 2; done; jq -c . $cdir/results/\$id.json"
    before=$(_boot_id) || {
        bad "leg 4b: could not read the boot id before the power probes"
        return
    }
    id=$rid_bad
    out=$(_ssh "id=$id; printf '%s\n' '{\"id\":\"$id\",\"action\":\"power-reboot\",\"actor\":\"admin\",\"confirm\":\"reboot\"}' > $cdir/requests/$id.json; $plant" 2>/dev/null)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "rejected" ] && [ "$(_boot_id)" = "$before" ]; then
        ok "leg 4b: a wrong confirm word is rejected on the host and the machine keeps running"
    else
        bad "leg 4b: a wrong confirm word was not rejected cleanly (got: $(printf '%s' "$out" | cut -c1-200))"
    fi
    id=$rid_reboot
    out=$(_ssh "id=$id; printf '%s\n' '{\"id\":\"$id\",\"action\":\"power-reboot\",\"actor\":\"admin\",\"confirm\":\"REBOOT\"}' > $cdir/requests/$id.json; $plant" 2>/dev/null)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "rebooting" ]; then
        ok "leg 4b: power-reboot answered rebooting"
    else
        bad "leg 4b: power-reboot did not answer rebooting (got: $(printf '%s' "$out" | cut -c1-200))"
        return
    fi
    if _wait_new_boot "$before" 420; then
        ok "leg 4b: the appliance rebooted on the power-reboot request"
    else
        bad "leg 4b: no new boot after power-reboot"
        return
    fi
    audit=$(_ssh "cat $cdir/audit/control.log" 2>/dev/null)
    case "$audit" in
    *'"actor":"admin","action":"power-reboot","status":"rebooting"'*) ok "leg 4b: the power-reboot audit line survived the reboot" ;;
    *) bad "leg 4b: no power-reboot audit line in the control log" ;;
    esac
    if _ssh "journalctl -b -1 -u pithead-control.service --no-pager | grep -F 'Stack stopped before power-reboot'" >/dev/null 2>&1; then
        ok "leg 4b: the stack was stopped cleanly before the reboot was ordered"
    else
        bad "leg 4b: the previous boot's control journal has no clean-stop line before the reboot"
    fi
    deadline=$(($(date +%s) + 900))
    until curl -sSk -u "$DASH_USER:$DASH_PASS" -o /dev/null -f -m 8 "https://$ip/api/state" 2>/dev/null; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            bad "leg 4b: the dashboard did not come back after the power-reboot"
            return
        }
        sleep 10
    done
    ok "leg 4b: the stack and dashboard came back after the reboot"
    _ssh "rm -f $cdir/results/$rid_reboot.json $cdir/power-cooldown"
    id=$rid_off
    out=$(_ssh "id=$id; printf '%s\n' '{\"id\":\"$id\",\"action\":\"power-shutdown\",\"actor\":\"admin\",\"confirm\":\"SHUTDOWN\"}' > $cdir/requests/$id.json; $plant" 2>/dev/null)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "shutting-down" ]; then
        ok "leg 4b: power-shutdown answered shutting-down"
    else
        bad "leg 4b: power-shutdown did not answer shutting-down (got: $(printf '%s' "$out" | cut -c1-200))"
        return
    fi
    deadline=$(($(date +%s) + 300))
    until [ "$(virsh domstate "$VM" 2>/dev/null | head -1)" = "shut off" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            bad "leg 4b: the machine never powered off after power-shutdown"
            return
        }
        sleep 5
    done
    ok "leg 4b: the machine powered off on the power-shutdown request and stayed off"
    virsh start "$VM" >/dev/null 2>&1 || {
        bad "leg 4b: could not power the guest back on after the shutdown probe"
        return
    }
    if ! _wait_ssh 420; then
        bad "leg 4b: the guest did not return after being powered back on"
        return
    fi
    audit=$(_ssh "cat $cdir/audit/control.log" 2>/dev/null)
    case "$audit" in
    *'"actor":"admin","action":"power-shutdown","status":"shutting-down"'*) ok "leg 4b: the power-shutdown audit line was written before power-off" ;;
    *) bad "leg 4b: no power-shutdown audit line in the control log" ;;
    esac
    if _ssh "journalctl -b -1 -u pithead-control.service --no-pager | grep -F 'Stack stopped before power-shutdown'" >/dev/null 2>&1; then
        ok "leg 4b: the stack was stopped cleanly before the power-off"
    else
        bad "leg 4b: the previous boot's control journal has no clean-stop line before the power-off"
    fi
    deadline=$(($(date +%s) + 900))
    until curl -sSk -u "$DASH_USER:$DASH_PASS" -o /dev/null -f -m 8 "https://$ip/api/state" 2>/dev/null; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            bad "leg 4b: the dashboard did not come back after the power-on"
            return
        }
        sleep 10
    done
    ok "leg 4b: the stack and dashboard came back after the power-on"
}
