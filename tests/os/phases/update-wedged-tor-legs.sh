# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_wedged_tor_plant() {
    info "planting the #3052 saturated circuit-build history on the shared /data (the #4049 wedge)"
    _ssh bash -s <<'GUEST'
set -e
cd /data/pithead
data=$(sed -n 's/^TOR_DATA_DIR=//p' .env)
[ -s "$data/state" ]
work=$(mktemp -d)
cp "$data/state" "$work/original-state"
docker compose stop tor >/dev/null 2>&1
awk '!/^CircuitBuild/ && !/^TotalBuildTimes /' "$work/original-state" >"$data/state"
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >>"$data/state"
grep -qx 'CircuitBuildAbandonedCount 1000' "$data/state"
grep -qx 'TotalBuildTimes 1000' "$data/state"
! grep -q '^CircuitBuildTimeBin ' "$data/state"
docker compose start tor >/dev/null 2>&1
for _ in $(seq 90); do
    s=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(docker compose ps -aq tor | head -n 1)" 2>/dev/null)
    [ "$s" = unhealthy ] && exit 0
    sleep 10
done
exit 1
GUEST
}
_wedged_tor_still_wedged() {
    local out
    out=$(_ssh "cd /data/pithead && docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}} {{json .State.Health}}' \"\$(docker compose ps -aq tor | head -n 1)\" 2>/dev/null" 2>/dev/null)
    case "$out" in
    unhealthy*) ;;
    *)
        printf '%s' "$out"
        return 1
        ;;
    esac
}
_wedged_tor_advisory_wait() {
    local deadline=$(($(date +%s) + $1))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        _ssh "journalctl -u pithead-boot -b 0 2>/dev/null | grep -F 'commits with the fault recorded as advisory' >/dev/null" && return 0
        sleep 15
    done
    return 1
}
_update_wedged_tor_reboot_leg() {
    info "leg 6 — a Tor wedge on the shared data must not cost the committed slot its fallback (#4049): plain reboot"
    if ! _wedged_tor_plant; then
        bad "leg 6: the saturated tor state never made the tor container unhealthy — the wedge was never live, so the rest of this leg would prove nothing"
        return
    fi
    ok "leg 6: tor runs wedged (unhealthy, saturated state on /data)"
    local before marker
    before=$(_boot_id) || {
        bad "leg 6: could not read the boot id before the plain reboot"
        return
    }
    _ssh 'reboot' >/dev/null 2>&1 || true
    _wait_new_boot "$before" 420 || {
        bad "leg 6: guest never returned after the plain reboot"
        return
    }
    marker=$(SSH_TIMEOUT=20 _ssh cat /etc/pithead-test-marker 2>/dev/null)
    [ "$marker" = "v2" ] && ok "leg 6: the wedged box booted back onto its committed slot (v2)" ||
        bad "leg 6: expected v2 to boot after the reboot, got '${marker:-none}'"
    if _wedged_tor_advisory_wait 2160; then
        ok "leg 6: the boot gate committed through the network advisory instead of spending the fallback"
    else
        bad "leg 6: 36 minutes after the reboot pithead-boot never logged the advisory commit — fail_boot ran (or the gate is still holding), and the box just spent its fallback on the network"
        return
    fi
    if _ssh "journalctl -u pithead-boot -b 0 2>/dev/null | grep -F 'saturated and clearnet egress is down' >/dev/null"; then
        ok "leg 6: the commit named the network fault it was committing through"
    else
        bad "leg 6: the advisory commit did not name the saturated tor history it was committing through"
    fi
    if ! _ssh "journalctl -u pithead-boot -b 0 2>/dev/null | grep -F 'never became healthy' >/dev/null"; then
        ok "leg 6: no fail_boot this boot — the window ended in a commit, not in a reboot decision"
    else
        bad "leg 6: fail_boot still ran on a wedged-network boot"
    fi
    _wedged_tor_still_wedged >/dev/null &&
        ok "leg 6: the wedge is still live after the commit (the fault was survived, not cleared)" ||
        bad "leg 6: tor recovered by itself during the leg — the leg was not run against a live wedge"
    if _dash_marker_served v2 300; then
        ok "leg 6: the dashboard serves through the wedge"
    else
        bad "leg 6: the dashboard never served v2 through the wedge"
    fi
    if _ssh "test ! -e /data/pithead/.boot-gate-failures"; then
        ok "leg 6: the boot-failure counter stayed clear, so a later real fault still gets its one reboot"
    else
        bad "leg 6: .boot-gate-failures exists after the advisory commit"
    fi
    local after
    after=$(_boot_id) || after=""
    [ -n "$after" ] && [ "$after" = "$before" ] &&
        ok "leg 6: the machine rebooted exactly for the plain reboot — fail_boot never fired behind the commit" ||
        bad "leg 6: the boot id changed again during the leg — something rebooted this box behind the gate"
    marker=$(SSH_TIMEOUT=20 _ssh cat /etc/pithead-test-marker 2>/dev/null)
    [ "$marker" = "v2" ] && ok "leg 6: still v2 at the end of the window — no GRUB fallback" ||
        bad "leg 6: the guest left v2 during the window (marker '${marker:-none}')"
}
_update_wedged_tor_update_leg() {
    info "leg 7 — an OS update while Tor stays wedged must commit, with the fault recorded as advisory (#4049)"
    local fbundle fbrc tag srv srv_pid host_addr port=8932 aged out before marker
    info "leg 7: building the v3wedge bundle (the wedge is still planted; nothing about this bundle is special)"
    fbundle=$(_build_bundle v3wedge)
    fbrc=$?
    if [ "$fbrc" -ne 0 ] || [ -z "$fbundle" ]; then
        bundle_build_evidence
        bad "leg 7: the v3wedge bundle build failed — read /tmp/os-fault-bundle.log"
        return
    fi
    ok "leg 7: built the bundle: $(basename "$fbundle")"
    tag="v$(tr -d ' \t\r\n' <VERSION)"
    srv=$(mktemp -d)
    cp "$fbundle" "$srv/pithead-os-$tag.raucb"
    printf '{"tag_name":"%s","html_url":"http://bench.invalid/rel","assets":[{"name":"pithead-os-%s.raucb","size":%s}]}' \
        "$tag" "$tag" "$(wc -c <"$srv/pithead-os-$tag.raucb" | tr -d ' ')" >"$srv/releases-latest.json"
    host_addr=$(ip -4 -o addr show virbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$host_addr" ] || host_addr="192.168.122.1"
    if ! srv_pid=$(_serve_update_dir "$srv" "$port"); then
        rm -rf "$srv"
        bad "leg 7: the bench release server never answered on :$port — the harness, not the product"
        return
    fi
    if ! aged=$(aged_version "${tag#v}") || ! _ssh "printf 'http://$host_addr:$port' > /data/pithead/os-update-test-base && printf '%s\n' '$aged' > /data/pithead/VERSION"; then
        kill "$srv_pid" 2>/dev/null
        rm -rf "$srv"
        bad "leg 7: could not age the guest or plant the update-server seam"
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
        ok "leg 7: bundle installed into the spare slot over the wedge through the dashboard action"
    else
        bad "leg 7: the dashboard could not check, download, verify and install the bundle (got: $(printf '%s' "$out" | cut -c1-200))"
        return
    fi
    before=$(_boot_id) || {
        bad "leg 7: could not read the boot id before the update reboot"
        return
    }
    _os_step '{"action":"reboot"}' 30 >/dev/null 2>&1 || true
    _wait_new_boot "$before" 420 || {
        bad "leg 7: guest never returned after booting the updated slot"
        return
    }
    marker=$(SSH_TIMEOUT=20 _ssh cat /etc/pithead-test-marker 2>/dev/null)
    [ "$marker" = "v3wedge" ] && ok "leg 7: the updated slot booted (v3wedge)" || {
        bad "leg 7: expected v3wedge booted after install, got '${marker:-none}'"
        return
    }
    if _wedged_tor_advisory_wait 2160; then
        ok "leg 7: the update committed through the network advisory — the wedge never reached fail_boot"
    else
        bad "leg 7: 36 minutes into the updated boot there is no advisory commit; marker now: $(SSH_TIMEOUT=20 _ssh cat /etc/pithead-test-marker 2>/dev/null)"
        return
    fi
    local verdict
    verdict=$(_ssh "cat /data/pithead/data/control/results/os-update-state.json" 2>/dev/null)
    if printf '%s' "$verdict" | jq -e '.verdict.outcome == "updated" and ((.verdict.advisory | length) >= 1)' >/dev/null 2>&1; then
        ok "leg 7: the dashboard's update verdict is updated, with the fault recorded as advisory"
    else
        bad "leg 7: the update verdict is not an updated-with-advisory: $(printf '%s' "$verdict" | cut -c1-200)"
    fi
    if printf '%s' "$verdict" | jq -e '[.verdict.advisory[] | select(contains("saturated and clearnet egress is down"))] | length >= 1' >/dev/null 2>&1; then
        ok "leg 7: the advisory names the wedged tor fault it committed through"
    else
        bad "leg 7: the advisory does not name the tor fault"
    fi
    if _ssh "test ! -e /data/pithead/data/os-update/in-flight.json"; then
        ok "leg 7: the in-flight flag was consumed by the commit (the next boot reads updated, not rolled_back)"
    else
        bad "leg 7: the in-flight flag survived the commit"
    fi
    _wedged_tor_still_wedged >/dev/null &&
        ok "leg 7: tor is still wedged on the committed update — the update was committed through the fault, not after it cleared" ||
        bad "leg 7: tor recovered during the leg — this run did not stay wedged"
    if _dash_marker_served v3wedge 300; then
        ok "leg 7: the dashboard of the committed update serves through the wedge"
    else
        bad "leg 7: the dashboard never served v3wedge through the wedge"
    fi
    marker=$(SSH_TIMEOUT=20 _ssh cat /etc/pithead-test-marker 2>/dev/null)
    [ "$marker" = "v3wedge" ] && ok "leg 7: still v3wedge at the end of the window — the update kept its slot" ||
        bad "leg 7: the guest left v3wedge during the window (marker '${marker:-none}')"
}
phase_update_wedged_tor_legs() {
    local fail_before=$FAIL
    if [ "${LEG4_PITHEAD_BOOT_PROVED:-0}" != "1" ]; then
        it_skip_leg "wedged-Tor boot gate commit (#4049)" \
            "leg 4 did not reach a committed, provisioned guest on this run, so there is no live pithead-boot to reboot or update through a wedge" missing
        return
    fi
    _update_wedged_tor_reboot_leg
    _update_wedged_tor_update_leg
    if [ "$FAIL" -gt "$fail_before" ]; then
        rollback_evidence "$SERIAL.leg67-evidence"
        info "legs 6-7 failure evidence (boot journal, verdict, grubenv, doctor) kept at $SERIAL.leg67-evidence"
        bash scripts/sanitize-test-log.sh --lines 200 "$SERIAL.leg67-evidence"
    fi
}
