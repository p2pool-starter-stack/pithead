# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
: "${OS_RUN_SUITE:?source via the suite runner}"

_ru_head_boot() {
    local img aged
    realupgrade_stamp negctlhead build-head-image
    img=$(_build_image v1) || {
        bad "negctlhead: the head-built old image could not be built"
        return 1
    }
    _vm_boot_disk "$img" && _wait_ssh 900 || {
        bad "negctlhead: the head-built old guest never answered SSH"
        return 1
    }
    _wizard_provision_capture 0 || {
        bad "negctlhead: provisioning the head-built old guest failed (${WIZ_FAIL_REASON:-no reason})"
        return 1
    }
    if provisioning_settled 900 && ! provisioning_setup_failed; then
        ok "negctlhead: the head-built old guest is provisioned ($(provisioning_state))"
    else
        bad "negctlhead: provisioning never finished ($(provisioning_state))"
        return 1
    fi
    aged=$(aged_version "${RU_NEW_TAG#v}") || {
        bad "negctlhead: cannot age the running version below ${RU_NEW_TAG#v}"
        return 1
    }
    _ssh "printf '%s\n' '$aged' > /data/pithead/VERSION && printf '%s' '$RU_BASE' > /data/pithead/os-update-test-base" || {
        bad "negctlhead: could not age the guest or plant the update seam"
        return 1
    }
    _ru_wait_state 600 || {
        bad "negctlhead: the head-built old dashboard never served /api/state"
        return 1
    }
}

_ru_negctl_head_leg() {
    local n=0 os_json="" verdict_ok=0 out
    realupgrade_stamp negctlhead start
    _ru_head_boot || return 1
    _ru_install_candidate negctlhead || return 1
    realupgrade_stamp negctlhead reboot-ordered
    _ru_order_reboot negctlhead || return 1
    while [ "$n" -lt 5 ]; do
        n=$((n + 1))
        virsh destroy "$VM" >/dev/null 2>&1 && virsh start "$VM" >/dev/null 2>&1 || {
            bad "negctlhead: could not hard-reset the guest (try $n)"
            return 1
        }
        _wait_dhcp_ip 120 || true
        _wait_ssh 600 || {
            bad "negctlhead: the guest never answered SSH after reset $n"
            return 1
        }
        if [ "$(_marker)" != v1 ]; then
            realupgrade_stamp negctlhead candidate-up-reset-again
            continue
        fi
        _ru_wait_state 900 || continue
        os_json=$(_ru_os)
        printf '%s' "$os_json" | jq -e '.verdict.outcome == "rolled_back"' >/dev/null 2>&1 && {
            verdict_ok=1
            break
        }
    done
    if [ "$verdict_ok" != 1 ]; then
        bad "negctlhead: no rolled_back verdict after $n hard resets (last: $(printf '%s' "$os_json" | jq -c '.verdict // .step' 2>/dev/null | cut -c1-200))"
        return 1
    fi
    ok "negctlhead: a hard reset of the uncommitted slot rolled back to the head-built slot ($(printf '%s' "$os_json" | jq -c '.verdict' | cut -c1-200))"
    if out=$(rollback_verdict_check "$os_json" "$REALUPGRADE_ROLLBACK_CAUSE") && printf '%s' "$os_json" | jq -e '.verdict.interrupted == true' >/dev/null 2>&1; then
        ok "negctlhead: the rollback names its cause ($REALUPGRADE_ROLLBACK_CAUSE)"
    else
        bad "negctlhead: the rollback recorded no explicit cause (${out:-interrupted flag missing})"
    fi
    sensitive_preview "$(dashboard_config_body "$(dashboard_curl -sSk -m 10 "https://$ip/api/config" | jq -c .)")" &&
        [ "$(printf '%s' "$APPROVAL_PREVIEW" | jq -r '.status')" = "previewed" ] && ok "negctlhead: the configuration is still saveable after the rollback" ||
        bad "negctlhead: the configuration is not saveable after the rollback ($(printf '%s' "$APPROVAL_PREVIEW" | cut -c1-200))"
    realupgrade_stamp negctlhead finished
}
