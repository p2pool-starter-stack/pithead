# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
: "${OS_RUN_SUITE:?source via the suite runner}"

_ru_soak_leg() {
    local half=$((REALUPGRADE_SOAK_S / 2)) before_boot after_boot units sentinels live fails tls_after cfg host port user_ok
    realupgrade_stamp soak start
    sleep "$half"
    before_boot=$(_boot_id) || before_boot=""
    realupgrade_stamp soak extra-reboot
    _reboot_wait "reboot" 600 || {
        bad "soak: the guest never returned after the one extra reboot"
        _ru_save_failure soak
        return 1
    }
    after_boot=$(_boot_id) || after_boot=""
    [ -n "$before_boot" ] && [ -n "$after_boot" ] && [ "$after_boot" != "$before_boot" ] && ok "soak: the extra reboot happened (new boot id)" || bad "soak: the extra reboot is not visible in the boot id"
    sleep "$half"
    if provisioning_settled 900 && ! provisioning_setup_failed; then
        ok "soak: provisioning settled after the extra reboot"
    else
        bad "soak: provisioning did not settle after the extra reboot ($(provisioning_state))"
    fi
    if _ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json >/dev/null 2>&1"; then
        ok "soak: doctor passes without PITHEAD_BOOT_GATE=1"
    else
        bad "soak: doctor refuses the settled stack without the boot-gate relaxation: $(_ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json 2>/dev/null | jq -r '[.checks[]? | select(.status==\"fail\") | .message] | join(\"; \")'" | cut -c1-300)"
    fi
    if units=$(_ssh "systemctl --failed --no-legend --no-pager --plain" 2>/dev/null); then
        fails=$(printf '%s\n' "$units" | awk '$1 !~ /^[0-9a-f]{64}-[0-9a-f]+\.service$/' | tr -s ' ' | tr '\n' ';')
        [ -z "${fails//[; ]/}" ] && ok "soak: no unit is failed" || bad "soak: failed unit(s): $fails"
    else
        bad "soak: the failed-unit list could not be read over SSH"
    fi
    case "$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')" in
    *B_OK=1*B_TRY=0* | *B_TRY=0*B_OK=1*) ok "soak: the slot is still good" ;;
    *) bad "soak: the slot is not good in grubenv" ;;
    esac
    cfg=$(dashboard_curl -sSk -m 10 "https://$ip/api/config")
    host=$(printf '%s' "$cfg" | jq -r '.dashboard.host')
    port=$(printf '%s' "$cfg" | jq -r '.p2pool.stratum_port')
    [ "$host" = "$RU_HOST_NAME" ] && [ "$port" = "$RU_STRATUM_PORT" ] && ok "soak: the aged config is unchanged (host $host, stratum port $port)" ||
        bad "soak: the aged config changed (host '$host', stratum port '$port')"
    sensitive_preview "$(dashboard_config_body "$(printf '%s' "$cfg" | jq -c .)")" &&
        [ "$(printf '%s' "$APPROVAL_PREVIEW" | jq -r '.status')" = "previewed" ] && ok "soak: the config is still saveable (a no-op preview is accepted)" ||
        bad "soak: the config is no longer saveable ($(printf '%s' "$APPROVAL_PREVIEW" | cut -c1-200))"
    [ "$(printf '%s' "$cfg" | jq -r '.monero.wallet_address')" = "$HARNESS_WALLET" ] && [ "$(printf '%s' "$cfg" | jq -r '.tari.wallet_address')" = "$HARNESS_TARI" ] &&
        ok "soak: the public-address-only wallets are unchanged" || bad "soak: a wallet address changed across the update"
    user_ok=$(dashboard_curl -sSk -m 8 -o /dev/null -w '%{http_code}' "https://$ip/api/state")
    [ "$user_ok" = 200 ] && ok "soak: the changed dashboard password still authenticates" || bad "soak: the changed password no longer authenticates (HTTP $user_ok)"
    sentinels=$(_ssh "cat /data/pithead/data/realupgrade-seed.json" 2>/dev/null)
    live=$(_ssh "printf '{\"monero\":\"%s\",\"tari\":\"%s\"}' \$(sha256sum /data/pithead/data/monero/realupgrade-sentinel | cut -d' ' -f1) \$(sha256sum /data/pithead/data/tari/realupgrade-sentinel | cut -d' ' -f1)" 2>/dev/null)
    [ -n "$sentinels" ] && [ "$(printf '%s' "$sentinels" | jq -cS .)" = "$(printf '%s' "$live" | jq -cS .)" ] && ok "soak: the chain-data sentinels are intact" ||
        bad "soak: a chain-data sentinel is missing or changed (seeded: ${sentinels:-none}, live: ${live:-none})"
    tls_after=$(_ru_tls_snapshot) || tls_after=""
    realupgrade_fingerprint_same "${TLS_BEFORE%%|*}" "${tls_after%%|*}" && ok "soak: the TLS fingerprint is unchanged" || bad "soak: the TLS fingerprint changed"
    realupgrade_sans_same "${TLS_BEFORE#*|}" "${tls_after#*|}" && ok "soak: the TLS SANs are unchanged" || bad "soak: the TLS SANs changed"
    getent hosts "$RU_HOST_NAME.local" >/dev/null 2>&1 && ok "soak: $RU_HOST_NAME.local resolves over mDNS" || bad "soak: $RU_HOST_NAME.local does not resolve over mDNS"
    if [ "$(tail -n1 "$RU_WORK/stratum.log" 2>/dev/null | cut -d' ' -f1)" = connected ]; then
        ok "soak: the stratum client is connected after the update and the extra reboot"
    else
        bad "soak: the stratum client is not connected (log: $(tail -n3 "$RU_WORK/stratum.log" 2>/dev/null | tr '\n' ';'))"
    fi
    realupgrade_stamp soak finished
}

_ru_negctl_leg() {
    local n=0 os_json="" verdict_ok=0 out
    realupgrade_stamp negctl start
    _ru_install_candidate negctl || {
        _ru_save_failure negctl
        return 1
    }
    realupgrade_stamp negctl reboot-ordered
    _ru_order_reboot negctl || return 1
    while [ "$n" -lt 5 ]; do
        n=$((n + 1))
        virsh destroy "$VM" >/dev/null 2>&1 || {
            bad "negctl: could not hard-reset the guest (try $n)"
            return 1
        }
        virsh start "$VM" >/dev/null 2>&1 || {
            bad "negctl: could not restart the guest (try $n)"
            return 1
        }
        _wait_dhcp_ip 120 || true
        if _wait_ssh 400; then
            realupgrade_stamp negctl candidate-up-reset-again
            continue
        fi
        _ru_wait_state 900 || continue
        os_json=$(_ru_os)
        printf '%s' "$os_json" | jq -e '.verdict.outcome == "rolled_back" and .verdict.interrupted == true' >/dev/null 2>&1 && {
            verdict_ok=1
            break
        }
    done
    if [ "$verdict_ok" = 1 ] && out=$(rollback_verdict_check "$os_json" "$REALUPGRADE_ROLLBACK_CAUSE"); then
        ok "negctl: a hard reset of the uncommitted slot rolled back with a recorded cause ($(printf '%s' "$os_json" | jq -c '.verdict.blocking' | cut -c1-200))"
    else
        bad "negctl: no rolled_back verdict with a blocking cause after $n hard resets (${out:-no verdict}; last: $(printf '%s' "$os_json" | jq -c '.verdict // .step' 2>/dev/null | cut -c1-200))"
        _ru_save_failure negctl
        return 1
    fi
    sensitive_preview "$(dashboard_config_body "$(dashboard_curl -sSk -m 10 "https://$ip/api/config" | jq -c .)")" &&
        [ "$(printf '%s' "$APPROVAL_PREVIEW" | jq -r '.status')" = "previewed" ] && ok "negctl: the old version's configuration is still saveable after the rollback" ||
        bad "negctl: the old version's configuration is not saveable after the rollback ($(printf '%s' "$APPROVAL_PREVIEW" | cut -c1-200))"
    realupgrade_stamp negctl finished
}
