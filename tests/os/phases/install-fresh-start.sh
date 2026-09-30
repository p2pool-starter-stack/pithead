# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# Continue the wipe=data leg on the installed disk, then return to the installer
# so the existing wipe=all and keep legs still run.
_phase_install_fresh_start() {
    info "Fresh Start reinstall — first boot, wizard, unaided reboot, RAUC commit (#2447)"
    local seed token="" jar scode tries=0 rstatus="" rootdev
    # Read the target ESP while the installer still owns the guest. A good status
    # after reboot cannot prove pithead-install seeded the copied grubenv.
    # shellcheck disable=SC2016  # expanded by the guest shell
    seed=$(_ssh 'T=$(mktemp -d) && mount -o ro /dev/vda1 "$T" && grub-editenv "$T/grub/grubenv" list; rc=$?; umount "$T" 2>/dev/null; rmdir "$T"; exit $rc' 2>/dev/null | tr '\n' ' ')
    if [ "$(_genv_field "$seed" A_OK)" = 1 ] && [ "$(_genv_field "$seed" B_OK)" = 0 ]; then
        ok "Fresh Start seeded the target grubenv before its first boot: $seed"
    else
        bad "Fresh Start target grubenv was not seeded: ${seed:-unreadable}"
        return 1
    fi

    _ssh 'systemctl poweroff' 2>/dev/null || true
    sleep 8
    vm_destroy_or_refuse || return
    : >"$SERIAL"
    kvm_preflight || exit 1
    # shellcheck disable=SC2154  # target_disk is local to phase_install
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$target_disk,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "Fresh Start target did not boot"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 300 || {
        bad "Fresh Start first boot never answered SSH"
        return 1
    }
    rootdev=$(_ssh "lsblk -no PKNAME \$(findmnt -no SOURCE /)" | head -1)
    [ "$rootdev" = vda ] || {
        bad "Fresh Start first boot left the target disk"
        return 1
    }
    ok "Fresh Start first boot reached the target disk"

    # wipe=data removed the old config, so finish the same wizard the operator
    # finished at M6 before expecting pithead-boot to run on boot two.
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    if [ -z "$token" ] || ! _wait_setup_page 120; then
        bad "Fresh Start wizard did not serve on the first boot"
        return 1
    fi
    jar=$(mktemp)
    # shellcheck disable=SC2154  # _wait_dhcp_ip sets the runner's ip
    if ! curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null ||
        ! grep -q wizard_session "$jar"; then
        bad "Fresh Start wizard authentication failed"
        rm -f "$jar"
        return 1
    fi
    scode=$(provision_browser_submit "$ip" "$jar")
    if [ "$scode" != 200 ]; then
        bad "Fresh Start wizard submit failed (HTTP ${scode:-none})"
        rm -f "$jar"
        return 1
    fi
    tries=0
    while [ "$tries" -lt 24 ]; do
        curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"' && break
        sleep 5
        tries=$((tries + 1))
    done
    if [ "$tries" -eq 24 ] || [ "$(curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null -w '%{http_code}' 2>/dev/null)" != 200 ]; then
        bad "Fresh Start wizard did not complete its credentials handoff"
        rm -f "$jar"
        return 1
    fi
    rm -f "$jar"
    if provisioning_settled 900 && ! provisioning_setup_failed; then
        ok "Fresh Start first boot provisioned ($(provisioning_state))"
    else
        bad "Fresh Start first boot did not provision ($(provisioning_state))"
        return 1
    fi
    seed=$(_read_genv)
    [ "$(_genv_field "$seed" A_OK)" = 1 ] && [ "$(_genv_field "$seed" B_OK)" = 0 ] || {
        bad "Fresh Start first boot lost the target's seeded slot: ${seed:-unreadable}"
        return 1
    }
    ok "Fresh Start first boot retained the seeded slot"
    _reboot_wait reboot 300 || {
        bad "Fresh Start second boot never returned"
        return 1
    }
    if provisioning_settled 900 && ! provisioning_setup_failed; then
        ok "Fresh Start second boot settled ($(provisioning_state))"
    else
        bad "Fresh Start second boot did not settle ($(provisioning_state))"
        return 1
    fi
    tries=0
    while [ "$tries" -lt 18 ]; do
        rstatus=$(_rauc_status)
        printf '%s' "$rstatus" | grep -q '^Activated: *rootfs\.' && break
        sleep 10
        tries=$((tries + 1))
    done
    _assert_rauc_committed "after Fresh Start boot 2"

    _ssh 'systemctl poweroff' 2>/dev/null || true
    sleep 8
    vm_destroy_or_refuse || return
    : >"$SERIAL"
    kvm_preflight || exit 1
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "installer did not return for the remaining wipe legs"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 240 || {
        bad "installer never answered after Fresh Start"
        return 1
    }
}
