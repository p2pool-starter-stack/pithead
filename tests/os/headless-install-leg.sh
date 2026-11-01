# shellcheck shell=bash
# shellcheck disable=SC2154
headless_install_stage() {
    local loop mnt tries=0 rc=0
    loop=$(losetup -Pf --show "$DISK") || return 1
    while [ ! -e "${loop}p1" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    if [ ! -e "${loop}p1" ]; then
        losetup -d "$loop"
        return 1
    fi
    mnt=$(mktemp -d) || {
        losetup -d "$loop"
        return 1
    }
    if mount "${loop}p1" "$mnt"; then
        if [ "$#" = 0 ]; then
            rm -f "$mnt/pithead-token.txt" "$mnt/pithead-config.json" "$mnt/pithead-target-serial.txt" || rc=1
        else
            printf '%s\n' 'PiT-K7m2Qx' >"$mnt/pithead-token.txt" &&
                printf '%s' "$1" >"$mnt/pithead-config.json" || rc=1
            if [ -n "${2:-}" ]; then
                printf '%s\n' "$2" >"$mnt/pithead-target-serial.txt" || rc=1
            else
                rm -f "$mnt/pithead-target-serial.txt" || rc=1
            fi
        fi
        umount "$mnt" || rc=1
    else
        rc=1
    fi
    rmdir "$mnt" || rc=1
    losetup -d "$loop" || rc=1
    return "$rc"
}

headless_install_auth() {
    local variant
    for variant in PiT-K7m2Qx pit-k7m2qx PIT-K7M2QX k7m2qx K7M2QX; do
        rm -f "$jar"
        if ! curl -fsSk -m 10 -c "$jar" --data-urlencode "token=$variant" "https://$ip/auth" -o /dev/null 2>/dev/null ||
            ! grep -q wizard_session "$jar"; then
            bad "staged setup token authenticates with supported case and prefix variants (#3071)"
            return 1
        fi
    done
    ok "staged setup token authenticates with supported case and prefix variants (#3071)"
}

headless_install_prefill_valid() {
    jq -e --argjson staged "$2" '
        .mode == "installer" and .stage == "installer" and .new_machine == false and
        .install_attempt == {} and ((.config * $staged) == .config)' <<<"$1" >/dev/null
}

headless_install_blank_valid() {
    jq -e '.mode == "installer" and .stage == "installer" and .new_machine == true and
        .install_attempt == {} and (.reference.monero.wallet_address | type) == "string" and
        (.reference.tari.wallet_address | type) == "string" and
        .config.monero.wallet_address == .reference.monero.wallet_address and
        .config.tari.wallet_address == .reference.tari.wallet_address' <<<"$1" >/dev/null
}

headless_install_rejection() {
    _ssh "printf '%s' '{malformed' >/boot/efi/pithead-config.json && sync" || return 1
    : >"$SERIAL"
    _reboot_wait reboot 300 && _wait_setup_page 180 || {
        bad "installer setup page returns after reboot with malformed preseed (#3071)"
        return 1
    }
    headless_install_auth || return 1
    local state_json
    state_json=$(curl -fsSk -m 10 -b "$jar" "https://$ip/api/wizard-state" 2>/dev/null) || state_json=""
    if wait_serial 'pre-seeded configuration was rejected' 30 && headless_install_blank_valid "$state_json"; then
        ok "malformed installer preseed is announced and opens a blank form with no disk selected (#3071)"
    else
        bad "malformed installer preseed is announced and opens a blank form with no disk selected (#3071)"
        return 1
    fi
}

headless_serial_boot() { # <stick-config> <serial> <target-disk> <target-serial> <foreign-disk> <foreign-serial> <fresh-disk> <fresh-serial>
    local err
    headless_install_stage "$1" "$2" || return 1
    : >"$SERIAL"
    kvm_preflight || exit 1
    err=$(virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,serial=PHSTICK01,boot.order=1" \
        --disk "path=$3,format=raw,bus=virtio,serial=$4,boot.order=2" \
        --disk "path=$5,format=raw,bus=scsi,serial=$6" \
        --disk "path=$7,format=raw,bus=virtio,serial=$8" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole 2>&1) || {
        bad "virt-install failed to define the serial-install VM: $(printf '%s' "$err" | tail -3 | tr '\n' ' ' | cut -c1-300)"
        return 1
    }
}

headless_serial_shut_off() {
    local tries=0
    while [ "$tries" -lt 60 ]; do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] && return 0
        sleep 5
        tries=$((tries + 1))
    done
    return 1
}

headless_serial_hashes() {
    local d
    for d in "$@"; do sha256sum "$d" | cut -d' ' -f1; done
}

headless_serial_leg() { # <stick-config> <target-disk> <target-serial> <foreign-disk> <foreign-serial>
    local config="$1" target_disk="$2" target_serial="$3" foreign_disk="$4" foreign_serial="$5"
    local fresh_disk="${foreign_disk%/*}/pithead-headless.img" fresh_serial="PHHEADLESS01" before after
    rm -f "$fresh_disk"
    qemu-img create -f raw "$fresh_disk" 30G >/dev/null || return 1
    before=$(headless_serial_hashes "$target_disk" "$foreign_disk" "$fresh_disk")
    vm_destroy_or_refuse || return 1
    headless_serial_boot "$config" PHNOMATCH01 "$target_disk" "$target_serial" "$foreign_disk" "$foreign_serial" "$fresh_disk" "$fresh_serial" || return 1
    if wait_serial 'offered disks match the serial file' 360 && _wait_setup_page 240 &&
        [ "$(virsh domstate "$VM" 2>/dev/null)" = running ]; then
        ok "a serial matching no attached disk refuses and opens the setup page (#979)"
    else
        bad "a serial matching no attached disk refuses and opens the setup page (#979)"
        return 1
    fi
    vm_destroy_or_refuse || return 1
    after=$(headless_serial_hashes "$target_disk" "$foreign_disk" "$fresh_disk")
    if [ "$before" = "$after" ]; then
        ok "the refused serial left every attached disk byte-for-byte untouched (#979)"
    else
        bad "the refused serial left every attached disk byte-for-byte untouched (#979)"
        return 1
    fi
    headless_serial_boot "$config" "$fresh_serial" "$target_disk" "$target_serial" "$foreign_disk" "$foreign_serial" "$fresh_disk" "$fresh_serial" || return 1
    if headless_serial_shut_off && wait_serial "Headless install complete" 5; then
        ok "the stick's serial file installed the named disk with no browser and powered off (#979)"
    else
        bad "the stick's serial file installed the named disk with no browser and powered off (#979)"
        return 1
    fi
    vm_destroy_or_refuse || return 1
    after=$(headless_serial_hashes "$target_disk" "$foreign_disk" "$fresh_disk")
    if [ "$(printf '%s\n' "$before" | sed -n 1,2p)" = "$(printf '%s\n' "$after" | sed -n 1,2p)" ] &&
        [ "$(printf '%s\n' "$before" | sed -n 3p)" != "$(printf '%s\n' "$after" | sed -n 3p)" ]; then
        ok "only the named disk changed; the other two stayed byte-for-byte untouched (#979)"
    else
        bad "only the named disk changed; the other two stayed byte-for-byte untouched (#979)"
        return 1
    fi
    rm -f "$fresh_disk"
}
