# shellcheck shell=bash
# shellcheck disable=SC2154 # guest address shared by the suite runner
: "${OS_RUN_SUITE:?source via the suite runner}"
phase_power() {
    # shellcheck disable=SC2034
    local token="" jar="" scode="" marker="" tries=0 code="" pv_user="" pv_pass="" PROVISION_DASHBOARD_HOST=fixture-box
    _phase_provision_initial || {
        bad "power: guest provisioning failed before the power verbs"
        return 1
    }
    DASH_USER=$pv_user
    DASH_PASS=$pv_pass
    info "power — host power-reboot and power-shutdown on the committed, provisioned guest (#4084)"
    local cdir=/data/pithead/data/control before out id deadline audit
    local rid_bad="4084aaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    local plant="for i in \$(seq 90); do [ -f $cdir/results/\$id.json ] && break; sleep 2; done; jq -c . $cdir/results/\$id.json"
    before=$(_boot_id) || {
        bad "power: could not read the boot id before the power probes"
        return
    }
    id=$rid_bad
    out=$(_ssh "id=$id; printf '%s\n' '{\"id\":\"$id\",\"action\":\"power-reboot\",\"actor\":\"admin\",\"confirm\":\"reboot\"}' > $cdir/requests/$id.json; $plant" 2>/dev/null)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "rejected" ] && [ "$(_boot_id)" = "$before" ]; then
        ok "power: a wrong confirm word is rejected on the host and the machine keeps running"
    else
        bad "power: a wrong confirm word was not rejected cleanly (got: $(printf '%s' "$out" | cut -c1-200))"
    fi
    local attempt
    for attempt in $(seq 1 40); do
        id=$(printf '4084bb%02d-bbbb-4bbb-8bbb-bbbbbbbbbbbb' "$attempt")
        out=$(_ssh "id=$id; printf '%s\n' '{\"id\":\"$id\",\"action\":\"power-reboot\",\"actor\":\"admin\",\"confirm\":\"REBOOT\"}' > $cdir/requests/$id.json; $plant" 2>/dev/null)
        printf '%s' "$out" | jq -r '.error // ""' | grep -q 'lock' || break
        sleep 15
    done
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "rebooting" ]; then
        ok "power: power-reboot answered rebooting"
    else
        bad "power: power-reboot did not answer rebooting (got: $(printf '%s' "$out" | cut -c1-200))"
        return
    fi
    if _wait_new_boot "$before" 420; then
        ok "power: the appliance rebooted on the power-reboot request"
    else
        bad "power: no new boot after power-reboot"
        return
    fi
    audit=$(_ssh "cat $cdir/audit/control.log" 2>/dev/null)
    case "$audit" in
    *'"actor":"admin","action":"power-reboot","status":"rebooting"'*) ok "power: the power-reboot audit line survived the reboot" ;;
    *) bad "power: no power-reboot audit line in the control log" ;;
    esac
    if _ssh "journalctl -b -1 -u pithead-control.service --no-pager | grep -F 'Stopping the stack before power-reboot'" >/dev/null 2>&1; then
        ok "power: the stack stop ran before the reboot was ordered"
    else
        bad "power: the previous boot's control journal has no stack-stop line before the reboot"
    fi
    deadline=$(($(date +%s) + 900))
    until curl -sSk -u "$DASH_USER:$DASH_PASS" -o /dev/null -f -m 8 "https://$ip/api/state" 2>/dev/null; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            bad "power: the dashboard did not come back after the power-reboot"
            return
        }
        sleep 10
    done
    ok "power: the stack and dashboard came back after the reboot"
    _ssh "rm -f $cdir/power-cooldown"
    for attempt in $(seq 1 40); do
        id=$(printf '4084cc%02d-cccc-4ccc-8ccc-cccccccccccc' "$attempt")
        out=$(_ssh "id=$id; printf '%s\n' '{\"id\":\"$id\",\"action\":\"power-shutdown\",\"actor\":\"admin\",\"confirm\":\"SHUTDOWN\"}' > $cdir/requests/$id.json; $plant" 2>/dev/null)
        printf '%s' "$out" | jq -r '.error // ""' | grep -q 'lock' || break
        sleep 15
    done
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "shutting-down" ]; then
        ok "power: power-shutdown answered shutting-down"
    else
        bad "power: power-shutdown did not answer shutting-down (got: $(printf '%s' "$out" | cut -c1-200))"
        return
    fi
    deadline=$(($(date +%s) + 300))
    until [ "$(virsh domstate "$VM" 2>/dev/null | head -1)" = "shut off" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            bad "power: the machine never powered off after power-shutdown"
            return
        }
        sleep 5
    done
    ok "power: the machine powered off on the power-shutdown request and stayed off"
    virsh start "$VM" >/dev/null 2>&1 || {
        bad "power: could not power the guest back on after the shutdown probe"
        return
    }
    if ! _wait_ssh 420; then
        bad "power: the guest did not return after being powered back on"
        return
    fi
    audit=$(_ssh "cat $cdir/audit/control.log" 2>/dev/null)
    case "$audit" in
    *'"actor":"admin","action":"power-shutdown","status":"shutting-down"'*) ok "power: the power-shutdown audit line is in the control log after the power-off" ;;
    *) bad "power: no power-shutdown audit line in the control log" ;;
    esac
    if _ssh "journalctl -b -1 -u pithead-control.service --no-pager | grep -F 'Stopping the stack before power-shutdown'" >/dev/null 2>&1; then
        ok "power: the stack stop ran before the power-off"
    else
        bad "power: the previous boot's control journal has no stack-stop line before the power-off"
    fi
    deadline=$(($(date +%s) + 900))
    until curl -sSk -u "$DASH_USER:$DASH_PASS" -o /dev/null -f -m 8 "https://$ip/api/state" 2>/dev/null; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            bad "power: the dashboard did not come back after the power-on"
            return
        }
        sleep 10
    done
    ok "power: the stack and dashboard came back after the power-on"
}
