# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
: "${OS_RUN_SUITE:?source via the suite runner}"

_ru_lowver_boot() {
    local img lower
    realupgrade_stamp negctlv build-head-image
    lower=$(aged_version "${RU_NEW_TAG#v}") || {
        bad "negctlv: nothing sorts below ${RU_NEW_TAG#v} to bake into the old slot"
        return 1
    }
    img=$(_build_image v1) || {
        bad "negctlv: the head-built old image could not be built"
        return 1
    }
    cp "$img" "$RU_WORK/lowver.img" && realupgrade_with_slot_a "$RU_WORK/lowver.img" realupgrade_patch_version_root "$lower" || {
        bad "negctlv: could not bake VERSION $lower into the head-built old slot"
        return 1
    }
    ok "negctlv: head-built old slot carries baked VERSION $lower (planted path /opt/pithead/VERSION)"
    printf 'negctlv_baked_version=%s\n' "$lower" >>"$RU_EVIDENCE"
    _vm_boot_disk "$RU_WORK/lowver.img" && _wait_ssh 900 || {
        bad "negctlv: the head-built old guest never answered SSH"
        return 1
    }
    [ "$(_ssh 'tr -d "[:space:]" </data/pithead/VERSION' 2>/dev/null)" = "$lower" ] || {
        bad "negctlv: the running version is not the baked $lower"
        return 1
    }
    _wizard_provision_capture 0 || {
        bad "negctlv: provisioning the head-built old guest failed (${WIZ_FAIL_REASON:-no reason})"
        return 1
    }
    if provisioning_settled 900 && ! provisioning_setup_failed; then
        ok "negctlv: the head-built old guest runs $lower and is provisioned ($(provisioning_state))"
    else
        bad "negctlv: provisioning never finished ($(provisioning_state))"
        return 1
    fi
    _ssh "printf '%s' '$RU_BASE' > /data/pithead/os-update-test-base" || {
        bad "negctlv: could not plant the update seam"
        return 1
    }
    _ru_wait_state 600 || {
        bad "negctlv: the head-built old dashboard never served /api/state"
        return 1
    }
}

_ru_negctl_lowver_leg() {
    local n=0 os_json="" verdict_ok=0
    realupgrade_stamp negctlv start
    _ru_lowver_boot || return 1
    _ru_install_candidate negctlv || return 1
    realupgrade_stamp negctlv reboot-ordered
    _ru_order_reboot negctlv || return 1
    while [ "$n" -lt 5 ]; do
        n=$((n + 1))
        virsh destroy "$VM" >/dev/null 2>&1 && virsh start "$VM" >/dev/null 2>&1 || {
            bad "negctlv: could not hard-reset the guest (try $n)"
            return 1
        }
        _wait_dhcp_ip 120 || true
        _wait_ssh 600 || {
            bad "negctlv: the guest never answered SSH after reset $n"
            return 1
        }
        if [ "$(_marker)" != v1 ]; then
            realupgrade_stamp negctlv candidate-up-reset-again
            continue
        fi
        local vdeadline=$(($(date +%s) + 900))
        while [ "$(date +%s)" -lt "$vdeadline" ]; do
            os_json=$(_ru_os)
            printf '%s' "$os_json" | jq -e '.verdict.outcome == "rolled_back"' >/dev/null 2>&1 && {
                verdict_ok=1
                break
            }
            sleep 10
        done
        break
    done
    if [ "$verdict_ok" != 1 ]; then
        bad "negctlv: no rolled_back verdict after $n hard resets (last: $(printf '%s' "$os_json" | jq -c '.verdict // .step' 2>/dev/null | cut -c1-200))"
        return 1
    fi
    ok "negctlv: a hard reset of the uncommitted slot rolled back to the head-built lower-version slot ($(printf '%s' "$os_json" | jq -c '.verdict' | cut -c1-200))"
    if [ "$(realupgrade_cause_row "v$REALUPGRADE_CAUSE_FIX_VERSION" "$os_json")" = pass ]; then
        ok "negctlv: the rollback names its cause ($REALUPGRADE_ROLLBACK_CAUSE)"
    else
        bad "negctlv: the rollback recorded no explicit cause ($(printf '%s' "$os_json" | jq -c '.verdict' | cut -c1-200))"
    fi
    sensitive_preview "$(dashboard_config_body "$(dashboard_curl -sSk -m 10 "https://$ip/api/config" | jq -c .)")" &&
        [ "$(printf '%s' "$APPROVAL_PREVIEW" | jq -r '.status')" = "previewed" ] && ok "negctlv: the configuration is still saveable after the rollback" ||
        bad "negctlv: the configuration is not saveable after the rollback ($(printf '%s' "$APPROVAL_PREVIEW" | cut -c1-200))"
    realupgrade_stamp negctlv finished
}
