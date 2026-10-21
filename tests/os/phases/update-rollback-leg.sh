# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_update_wait_committed() {
    local marker="$1" tries=0
    while [ "$tries" -lt 150 ]; do
        if [ "$(SSH_TIMEOUT=20 _ssh cat /etc/pithead-test-marker 2>/dev/null)" = "$marker" ] &&
            SSH_TIMEOUT=20 _ssh 'slot=$(sed -n "s/.*rauc.slot=\([AB]\).*/\1/p" /proc/cmdline); test -n "$slot" && genv=$(grub-editenv /boot/efi/grub/grubenv list) && printf "%s\n" "$genv" | grep -qx "${slot}_OK=1" && printf "%s\n" "$genv" | grep -qx "${slot}_TRY=0"'; then
            return 0
        fi
        sleep 10
        tries=$((tries + 1))
    done
    return 1
}
_update_rollback_serves() {
    local tries=0 code
    while [ "$tries" -lt 90 ]; do
        # shellcheck disable=SC2154
        if SSH_TIMEOUT=20 _ssh 'cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json >/dev/null 2>&1' &&
            code=$(curl -sSk -m 8 -u "$DASH_USER:$DASH_PASS" -o /dev/null -w '%{http_code}' "https://$ip/api/state") &&
            [ "$code" = 200 ]; then
            return 0
        fi
        sleep 10
        tries=$((tries + 1))
    done
    return 1
}
phase_update_rollback_leg() {
    info "leg 6 — operator rollback serves the provisioned stack"
    if [ "${LEG4_PITHEAD_BOOT_PROVED:-0}" != 1 ]; then
        it_skip_leg "provisioned operator rollback" "leg 4 did not prove a provisioned committed guest" missing
        return
    fi
    local before bundle
    if [ "$(_marker)" != v2 ] || ! _update_wait_committed v2; then
        bad "leg 6: the good provisioned v2 fallback slot was not restored"
        return
    fi
    before=$(_identity_snapshot) || {
        bad "leg 6: could not snapshot the provisioned identities"
        return
    }
    bundle=$(_build_bundle v3rollback) || {
        bundle_build_evidence
        bad "leg 6: could not build the rollback candidate"
        return
    }
    if ! _stage_bundle "$bundle" ||
        ! _ssh 'cd /data/pithead && ./pithead os-update /data/update.bundle --yes'; then
        bad "leg 6: os-update could not install the rollback candidate"
        return
    fi
    if ! _reboot_wait reboot 300 || ! _update_wait_committed v3rollback; then
        bad "leg 6: pithead-boot did not commit the rollback candidate unattended"
        return
    fi
    ok "leg 6: the fresh provisioned rollback candidate committed unattended"
    _identity_unchanged "leg 6 update" "$before"
    if ! _reboot_wait "$(_rollback_cmd)" 300 || [ "$(_marker)" != v2 ]; then
        bad "leg 6: operator rollback did not return to the earlier v2 slot"
        return
    fi
    ok "leg 6: operator rollback returned to the earlier provisioned slot"
    if _update_rollback_serves; then
        ok "leg 6: rolled-back provisioned stack passes doctor and authenticated /api/state returns 200"
    else
        bad "leg 6: rolled-back provisioned stack does not pass doctor and serve authenticated /api/state"
    fi
    _identity_unchanged "leg 6 rollback" "$before"
}
