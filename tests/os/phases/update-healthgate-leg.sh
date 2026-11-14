# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# shellcheck disable=SC2154 # guest address shared by the suite runner
# leg 5 — a container whose OWN healthcheck fails must hold the gate (#2383, manual battery M9).
# Split from phases/update.sh (file-budget ratchet): called from phase_update right after
# phase_update_dashboard, on the same provisioned, committed guest leg 4 left behind.
#
# M9 on the HP appliance: a dev bundle whose dashboard healthcheck was replaced with `exit 1`
# committed anyway — the dashboard container ran and answered HTTP, doctor only judges the
# revenue containers (monerod/p2pool/tari), and nothing on the boot path read container health at
# all. This leg reproduces exactly that shape, and needs leg 4's provisioned, committed guest
# (pithead-boot.service is conditioned on config.json/machine-role, neither of which legs 1-3 ever
# write — see phase_update's #2055 G1 note) to have something for the new gate to hold.
_update_healthgate_leg_body() {
    info "leg 5 — a container whose OWN healthcheck fails must hold the gate (#2383, manual battery M9)"
    if [ "${LEG4_PITHEAD_BOOT_PROVED:-0}" != "1" ]; then
        it_skip_leg "unhealthy-container gate refusal (#2383)" \
            "leg 4 did not reach a committed, provisioned guest on this run, so there is no live pithead-boot to install a fault bundle against" missing
        return
    fi
    local fbundle fbrc marker fmarker fdeadline fserial_mark
    info "building v3fault bundle (dashboard healthcheck forced to 'exit 1')"
    export PITHEAD_TEST_BREAK_HEALTHCHECK=1
    fbundle=$(_build_bundle v3fault)
    fbrc=$?
    unset PITHEAD_TEST_BREAK_HEALTHCHECK
    if [ "$fbrc" -ne 0 ] || [ -z "$fbundle" ]; then
        bundle_build_evidence
        bad "leg 5: the healthcheck-fault bundle build failed — read the build output above (/tmp/os-fault-bundle.log)"
        return
    fi
    ok "leg 5: built the fault bundle: $(basename "$fbundle")"
    local tag srv srv_pid host_addr port=8931 aged out before
    tag="v$(tr -d ' \t\r\n' <VERSION)"
    srv=$(mktemp -d)
    cp "$fbundle" "$srv/pithead-os-$tag.raucb"
    printf '{"tag_name":"%s","html_url":"http://bench.invalid/rel","assets":[{"name":"pithead-os-%s.raucb","size":%s}]}' \
        "$tag" "$tag" "$(wc -c <"$srv/pithead-os-$tag.raucb" | tr -d ' ')" >"$srv/releases-latest.json"
    host_addr=$(ip -4 -o addr show virbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$host_addr" ] || host_addr="192.168.122.1"
    if ! srv_pid=$(_serve_update_dir "$srv" "$port"); then
        rm -rf "$srv"
        bad "leg 5: the bench release server never answered on :$port — the harness, not the product"
        return
    fi
    if ! aged=$(aged_version "${tag#v}") || ! _ssh "printf 'http://$host_addr:$port' > /data/pithead/os-update-test-base && printf '%s\n' '$aged' > /data/pithead/VERSION"; then
        kill "$srv_pid" 2>/dev/null
        rm -rf "$srv"
        bad "leg 5: could not age the guest or plant the update-server seam"
        return
    fi
    _ssh 'rm -f /data/pithead/data/os-update/.check-stamp /data/pithead/data/os-update/.check-stamp-short'
    out=$(_os_step '{"action":"check"}' 120)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "checked" ]; then
        out=$(_os_step "{\"action\":\"download\",\"version\":\"$tag\"}" 900)
        [ "$(printf '%s' "$out" | jq -r '.status')" = "downloaded" ] && out=$(_os_step '{"action":"verify"}' 180)
        [ "$(printf '%s' "$out" | jq -r '.status')" = "verified" ] && out=$(_os_step '{"action":"install"}' 900)
    fi
    kill "$srv_pid" 2>/dev/null
    rm -rf "$srv"
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "installed" ]; then
        ok "leg 5: fault bundle installed into the spare slot through the dashboard action"
    else
        bad "leg 5: the dashboard could not check, download, verify and install the fault bundle (got: $(printf '%s' "$out" | cut -c1-200))"
        return
    fi
    fserial_mark=$(wc -c <"$SERIAL") || {
        bad "leg 5: could not mark the serial console before the fault boot"
        return
    }
    before=$(_boot_id) || {
        bad "leg 5: could not read the boot id before the reboot intent"
        return
    }
    _os_step '{"action":"reboot"}' 30 >/dev/null 2>&1 || true
    _wait_new_boot "$before" 420 || {
        bad "leg 5: guest never returned after booting the fault slot"
        return
    }
    marker=$(SSH_TIMEOUT=20 _ssh cat /etc/pithead-test-marker 2>/dev/null)
    [ "$marker" = "v3fault" ] && ok "leg 5: the fault slot booted (v3fault)" || {
        bad "leg 5: expected v3fault booted after install, got '${marker:-none}'"
        return
    }
    # The gate loops up to 90x10s before rebooting itself once (#1065) — bound generously for that
    # plus image loading and stack start on the fallback slot.
    fdeadline=$(($(date +%s) + 1800))
    fmarker=""
    while [ "$(date +%s)" -lt "$fdeadline" ]; do
        fmarker=$(SSH_TIMEOUT=20 _ssh cat /etc/pithead-test-marker 2>/dev/null)
        [ "$fmarker" = "v2" ] && break
        sleep 15
    done
    if [ "$fmarker" = "v2" ]; then
        ok "leg 5: FALLBACK — the unhealthy dashboard held the gate and the guest fell back to v2"
    else
        bad "leg 5: expected the guest back on v2 after the fault boot's gate refusal, got '${fmarker:-none}' (30 min bound)"
        return
    fi
    if tail -c "+$((fserial_mark + 1))" "$SERIAL" | grep -F 'Pithead is still starting (' | grep -F 'of about 16 minutes). Leave it powered on: if an update never becomes healthy, the machine goes back to the previous version by itself.' >/dev/null; then
        ok "leg 5: the fault boot's serial console reports health-gate progress and automatic update fallback"
    else
        bad "leg 5: the fault boot's serial console has no health-gate progress and automatic update fallback line"
    fi
    if _ssh "journalctl -u pithead-boot -b -1 2>/dev/null | grep -F 'Pithead is still starting (' | grep -F 'of about 16 minutes). Leave it powered on: if an update never becomes healthy, the machine goes back to the previous version by itself.' >/dev/null"; then
        ok "leg 5: the fault boot's journal reports health-gate progress and automatic update fallback"
    else
        bad "leg 5: the fault boot's journal has no health-gate progress and automatic update fallback line"
    fi
    if _ssh "journalctl -u pithead-boot -b -1 2>/dev/null | grep -q 'container dashboard'"; then
        ok "leg 5: the fault boot's journal names the dashboard container that held the gate"
    else
        bad "leg 5: no 'container dashboard' line in the fault boot's journal — the gate did not name the cause"
    fi
    local flag
    flag=$(_ssh "cat /data/pithead/data/os-update/in-flight.json" 2>/dev/null)
    if out=$(rollback_blocking_check "$flag" . "container dashboard"); then
        ok "leg 5: the in-flight record the fallback boot read carries a blocking list naming the dashboard container"
    else
        bad "leg 5: in-flight record after the fallback: $out"
    fi
    # shellcheck disable=SC2154
    if rollback_banner_served "$ip" "$DASH_USER:$DASH_PASS" 300; then
        ok "leg 5: the dashboard serves a banner that names the blocking check ('Blocked by:')"
    else
        bad "leg 5: the served banner module has no 'Blocked by:' cause"
    fi
    local xjournal fjournal rdeadline=$(($(date +%s) + 1200))
    xjournal=$(_ssh "journalctl -u pithead-boot -b -1 2>/dev/null" 2>/dev/null)
    if grep -qF 'dashboard schema hold armed' <<<"$xjournal" && ! grep -qF 'dashboard schema hold released' <<<"$xjournal"; then
        ok "leg 5: the failed candidate boot armed the dashboard schema hold and never released it"
    else
        bad "leg 5: the failed candidate boot's journal does not show the dashboard schema hold armed and left unreleased"
    fi
    while [ "$(date +%s)" -lt "$rdeadline" ]; do
        _ssh "journalctl -u pithead-boot -b 0 2>/dev/null | grep -F 'dashboard schema hold released' >/dev/null" && break
        sleep 15
    done
    fjournal=$(_ssh "journalctl -u pithead-boot -b 0 2>/dev/null" 2>/dev/null)
    if grep -qF 'dashboard schema hold armed' <<<"$fjournal" && grep -qF 'dashboard schema hold released' <<<"$fjournal"; then
        ok "leg 5: the fallback boot armed the dashboard schema hold and released it once its own gate committed"
    else
        bad "leg 5: the fallback boot's journal has no schema hold arm and release lines (20 min bound) — the hold never ran to completion on the surviving boot"
    fi
}

phase_update_healthgate_leg() {
    local fail_before=$FAIL
    _update_healthgate_leg_body
    if [ "$FAIL" -gt "$fail_before" ]; then
        rollback_evidence "$SERIAL.leg5-evidence"
        info "leg 5 failure evidence (boot journal, verdict, grubenv, doctor) kept at $SERIAL.leg5-evidence"
        bash scripts/sanitize-test-log.sh --lines 200 "$SERIAL.leg5-evidence"
    fi
}

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
    *'"actor":"admin","action":"power-shutdown","status":"shutting-down"'*) ok "leg 4b: the power-shutdown audit line is in the control log after the power-off" ;;
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
