# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_phase_install_initial() {
    info "phase: disk install (USB-style boot -> pithead-install -> boot from the target)"

    info "building the installer image (test SSH key + marker v1)"
    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return 1
    }

    vm_destroy_or_refuse || return
    # shellcheck disable=SC2154  # shared through the assembled runner scope
    rm -f "$target_disk"
    cp "$img" "$DISK"
    # 16G, the smallest real stick the docs allow: ESP + two 4 GiB slots + data's 4 GiB minimum
    # must fit or repart creates nothing and the guest lands in an emergency shell — which is
    # exactly what this sizing proves cannot happen on supported media.
    qemu-img resize "$DISK" 16G >/dev/null 2>&1 || true
    # The target: blank, larger than the source medium, so the grow assertions distinguish the
    # two disks beyond doubt.
    qemu-img create -f raw "$target_disk" 30G >/dev/null
    # M4's wrong-disk guard: a disk holding unrelated data that must be OFFERED for erasure and
    # left alone when the operator installs to the target instead. scsi (not virtio) gives QEMU's
    # native SCSI model; virtio-blk has no such field. serial= works on either bus, so the target
    # also gets one; its MODEL stays "unknown" as a real NVMe/virtio target's often does.
    local foreign_disk="/srv/code/bench-vm/pithead-foreign.img"
    local foreign_serial="PHFOREIGN01" foreign_model="QEMU HARDDISK" target_serial="PHTARGET01"
    # The stick gets one as well — not for the inventory's sake (it must never appear there) but
    # so the exclusion assertion below has an expectation the HARNESS owns. See that assertion.
    local stick_serial="PHSTICK01"
    rm -f "$foreign_disk"
    # 5G, not a token size: the negative control at the end INSTALLS to this disk, and
    # pithead-install's partition_fresh lays down a 256 MiB ESP plus a 4 GiB slot A. Anything
    # under ~4.25 GiB makes sgdisk fail first, and the control would then be reporting a disk too
    # small to partition rather than the wrong-disk guard it exists to test. Raw and sparse, so
    # the extra size costs nothing until written.
    qemu-img create -f raw "$foreign_disk" 5G >/dev/null
    : >"$SERIAL"
    # The image rides a USB bus with removable=on — that is what makes the guest a faithful
    # analog of a user's stick: the host-side gate (installer_mode_available) keys on
    # /sys/block/*/removable, which virtio never sets.
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    local virt_install_err
    virt_install_err=$(virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,serial=$stick_serial,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,serial=$target_serial,boot.order=2" \
        --disk "path=$foreign_disk,format=raw,bus=scsi,serial=$foreign_serial" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole 2>&1) || {
        bad "virt-install failed to define the installer VM: $(printf '%s' "$virt_install_err" | tail -3 | tr '\n' ' ' | cut -c1-300)"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 240 || {
        bad "installer guest never answered SSH (ip: ${ip:-none})"
        return 1
    }
    ok "image boots as removable media ($ip)"

    # Plant the foreign disk's filesystem and sentinel before the inventory is read: M4 must
    # prove a disk that already carries someone else's data is still correctly offered for
    # erasure, not skipped for having a filesystem lsblk doesn't recognise as ours.
    _dev_by_serial() { _ssh "lsblk -drno NAME,SERIAL | awk -v s=\"$1\" '\$2==s{print \$1; exit}'"; }
    local foreign_dev foreign_hash
    foreign_dev=$(_dev_by_serial "$foreign_serial")
    [ -n "$foreign_dev" ] || {
        bad "the foreign disk (serial $foreign_serial) is not visible to the guest"
        return 1
    }
    foreign_hash=$(_ssh "mkfs.ext4 -q -F /dev/$foreign_dev >/dev/null &&
        m=\$(mktemp -d) && mount /dev/$foreign_dev \"\$m\" &&
        echo 'unrelated data on the other disk' >\"\$m/sentinel\" &&
        sha256sum \"\$m/sentinel\" | cut -d' ' -f1 &&
        umount \"\$m\"")
    [ -n "$foreign_hash" ] || {
        bad "could not plant the foreign disk's filesystem and sentinel"
        return 1
    }
    ok "planted a foreign filesystem + sentinel on the second disk ($foreign_dev, $foreign_hash)"

    out=$(_ssh "pithead-install --list")
    if printf '%s' "$out" | cut -f1 | grep -qx "vda"; then
        ok "inventory offers the internal disk (vda)"
    else
        bad "inventory does not offer vda — got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
        return 1
    fi
    # Echo the row itself: whether QEMU's native SCSI model reaches lsblk's MODEL column is not
    # knowable by inspection, so the log has to carry the observed evidence.
    local foreign_row
    foreign_row=$(printf '%s' "$out" | grep -F "$(printf '%s\t%s\tempty' "$foreign_model" "$foreign_serial")" | head -1)
    if [ -n "$foreign_row" ]; then
        ok "inventory lists the foreign disk for erasure with its real model and serial: $(printf '%s' "$foreign_row" | tr '\t' '|')"
    else
        bad "foreign disk row missing or wrong — got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        return 1
    fi
    # The boot medium must never be a target. Two things this assertion must NOT do, both of
    # which it did before:
    #   - derive its expectation from `lsblk -no PKNAME $(findmnt -no SOURCE /)`. That is
    #     character-for-character pithead-install's own boot_disk(), so the check and the code it
    #     checks shared one oracle: if boot_disk() resolved the wrong disk, or none, the
    #     expectation moved with it and the assertion could not fail.
    #   - treat an unresolvable name as "nothing to compare, so pass". An expectation the harness
    #     cannot compute is a broken harness, and a check that cannot fail is not a check.
    # So: the name comes from the serial this phase itself put on the stick, and an empty answer
    # fails loudly.
    local stick_dev
    stick_dev=$(_dev_by_serial "$stick_serial")
    if [ -z "$stick_dev" ]; then
        bad "the boot medium (serial $stick_serial) is not visible to the guest — the exclusion check below would prove nothing"
        return 1
    fi
    if printf '%s' "$out" | cut -f1 | grep -qx "$stick_dev"; then
        bad "inventory offers the boot medium itself ($stick_dev)"
        return 1
    fi
    ok "inventory excludes the disk the system booted from ($stick_dev)"
    # The host wizard loop must be in installer mode — the same gate a real stick hits.
    # Poll: firstboot loads the wizard image from its tarball BEFORE publishing the inventory,
    # which takes about a minute on a first boot. Checking the moment SSH answers is a race the
    # standalone runs happened to win and the full gate lost.
    if _ssh "for i in \$(seq 36); do [ -s /data/pithead/data/firstboot/disks.tsv ] && exit 0; sleep 5; done; exit 1"; then
        ok "firstboot entered installer mode (inventory published to the spool)"
    else
        bad "firstboot did not publish a disk inventory — installer mode never engaged"
    fi

    # ---- the combined web flow, exactly as an operator drives it -------------------------
    # ONE page: config + disk + typed confirmation in one submission; the host validates
    # everything, publishes the credentials, and only the ack releases the erase. The machine
    # then installs, stages the accepted config for the target, and powers itself off.
    token=""
    tries2=0
    while [ -z "$token" ] && [ "$tries2" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries2=$((tries2 + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token on the installer console"
        return 1
    }
    ok "one-time token read from the installer console ($token)"
    # The token prints before the container finishes coming up — wait for the gate to SERVE
    # before authing, exactly as the provision phase does (and as a human's browser would).
    _wait_setup_page 120 || {
        bad "installer wizard never served its gate page"
        return 1
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "installer wizard auth failed"
        rm -f "$jar"
        return 1
    }
    # M3, proven through the page the operator actually reads, not just the CLI: lsblk -> the
    # host's spool -> this JSON is the whole pipeline the wizard's disk picker renders from.
    local state_json
    state_json=$(curl -fsSk -b "$jar" "https://$ip/api/wizard-state" 2>/dev/null)
    if printf '%s' "$state_json" | jq -e --arg s "$foreign_serial" --arg m "$foreign_model" \
        '.disks[]? | select(.serial == $s) | .model == $m and .state == "empty"' >/dev/null 2>&1; then
        ok "wizard page state carries the foreign disk's real model and serial (lsblk -> spool -> page)"
    else
        bad "wizard page state missing/wrong foreign disk row: $(printf '%s' "$state_json" | cut -c1-200)"
        rm -f "$jar"
        return 1
    fi

    body="monero_wallet=$HARNESS_WALLET&tari_wallet=$HARNESS_TARI&pool=mini&disk=vda&confirm=vda&wipe=keep"
    scode=$(curl -sSk -b "$jar" --data "$body" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "combined submit (config + disk) did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return 1
    }
    ok "ONE submission carried config + disk + confirmation"
    tries2=0
    while [ "$tries2" -lt 24 ]; do
        curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"' && break
        sleep 5
        tries2=$((tries2 + 1))
    done
    [ "$tries2" -lt 24 ] || {
        bad "credentials never published on the installer page — the erase would be releasable blind"
        rm -f "$jar"
        return 1
    }
    ok "credentials published BEFORE anything touched the disk"
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    # The ack releases the erase; the machine installs and powers ITSELF off.
    tries2=0
    while [ "$tries2" -lt 60 ]; do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] && break
        sleep 5
        tries2=$((tries2 + 1))
    done
    if [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ]; then
        ok "machine installed and switched itself off"
    else
        bad "machine never powered off after the ack"
        return 1
    fi
    vm_destroy_or_refuse || return
    # Boot from the TARGET alone — the stick is gone, exactly as the instructions tell the user.
    # The foreign disk travels with it: M4's whole point is what it looks like AFTER the install,
    # not just before.
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt_install_err=$(virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$target_disk,format=raw,bus=virtio" \
        --disk "path=$foreign_disk,format=raw,bus=scsi,serial=$foreign_serial" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole 2>&1) || {
        bad "virt-install failed to define the installed VM: $(printf '%s' "$virt_install_err" | tail -3 | tr '\n' ' ' | cut -c1-300)"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 300 || {
        bad "installed system never answered SSH (ip: ${ip:-none})"
        return 1
    }
    ok "installed system boots from the internal disk"

    # findmnt reports the by-partlabel symlink the cmdline named; resolve to the parent disk
    # before comparing, or the assertion fails on a correctly installed system.
    local rootdev
    rootdev=$(_ssh "lsblk -no PKNAME \$(findmnt -no SOURCE /)" | head -1)
    if [ "$rootdev" = "vda" ]; then
        ok "root is on the target disk, not a leftover medium"
    else
        bad "root is on '${rootdev:-unknown}' — expected the target disk (vda)"
    fi
    # THE assertion this phase exists for: the copy must include the slot's real /var, which the
    # overlay mount hides from a naive copy of /. An installed machine without a dpkg database
    # is subtly broken in ways no boot banner reveals.
    if _ssh "test -s /var/lib/dpkg/status"; then
        ok "copied system is complete (/var/lib/dpkg survived the overlay)"
    else
        bad "/var/lib/dpkg/status missing — the copy lost the slot's /var"
    fi
    if _ssh "test -s /etc/machine-id"; then
        ok "machine-id regenerated on the installed system"
    else
        bad "machine-id empty — identity was not regenerated"
    fi
    local data_gib
    data_gib=$(_ssh "df -BG --output=size /data 2>/dev/null | tail -1 | tr -dc '0-9'")
    if [ -n "$data_gib" ] && [ "$data_gib" -ge 15 ]; then
        ok "repart built /data on the target's own disk (${data_gib} GiB of 30)"
    else
        bad "/data on the target is '${data_gib:-none}' GiB — repart did not size it to the disk"
    fi
    _wizard_up() { _wait_setup_page 180; } # shared by both legs — first boots load the wizard image first
    # The staged config makes the first boot HEADLESS: the machine provisions itself and no
    # second wizard ever serves. The full stack-up is the provision phase's job; here we prove
    # the config arrived and provisioning began.
    if _ssh "for i in \$(seq 90); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        ok "staged config crossed to the installed system (headless provisioning began)"
    else
        bad "the config confirmed on the installer page never reached the installed system"
    fi
    if _ssh "journalctl -u pithead-firstboot -b --no-pager 2>/dev/null | grep -q pre-seeded"; then
        ok "installed system took the pre-seed path — no second wizard, no second token"
    else
        bad "installed system did not take the pre-seed path"
    fi
    # And no plaintext copy lingers: the staged file carried the dashboard password across, and
    # once consumed it must not sit on the installed machine's unencrypted ESP forever.
    if _ssh "test -f /boot/efi/pithead-config.json"; then
        bad "the consumed pre-seed (with credentials) is still on the installed system's ESP"
    else
        ok "consumed pre-seed removed from the installed system's ESP"
    fi

    # ---- M4: the disk left alone stays alone -----------------------------------------------
    # THE row this phase was missing: installing to vda must never touch the foreign disk. Found
    # by serial again — the scsi bus is free to renumber it now that the USB stick is gone.
    # umount runs unconditionally once mount succeeds — a failed hash comparison must not skip
    # it, or the negative control right below finds the disk still busy and reports "the
    # installer refused the disk" instead of the real M4 violation this block exists to catch.
    foreign_dev=$(_dev_by_serial "$foreign_serial")
    if [ -n "$foreign_dev" ] && _ssh "m=\$(mktemp -d) && mount -r /dev/$foreign_dev \"\$m\" || exit 9
            h=\$(sha256sum \"\$m/sentinel\" 2>/dev/null | cut -d' ' -f1)
            umount \"\$m\"
            [ \"\$h\" = \"$foreign_hash\" ]"; then
        ok "the foreign disk still mounts and its sentinel is byte-identical — M4 holds"
    else
        bad "the foreign disk was touched, lost its filesystem, or its sentinel changed"
    fi

    # ---- negative control: prove the check above is not vacuous ----------------------------
    # Deliberately install to the WRONG disk (the foreign one) and confirm the sentinel really
    # does disappear — otherwise a broken mount/hash check above would report "untouched" no
    # matter what a real wrong-disk bug did.
    local nc_out nc_rc=0
    if [ -z "$foreign_dev" ]; then
        bad "negative control: the foreign disk is not visible, so nothing was proven"
    else
        # Keep the installer's own stderr: a refusal here (too small to partition, disk in use)
        # is a different failure from a surviving sentinel, and the log must say which.
        nc_out=$(_ssh "pithead-install --target /dev/$foreign_dev --yes 2>&1") || nc_rc=$?
        if [ "$nc_rc" -ne 0 ]; then
            bad "negative control: the installer refused the foreign disk (rc $nc_rc): $(printf '%s' "$nc_out" | tail -3 | tr '\n' ' ' | cut -c1-200)"
        elif _ssh "m=\$(mktemp -d) && mount -r /dev/$foreign_dev \"\$m\" 2>/dev/null &&
            test -e \"\$m/sentinel\""; then
            bad "negative control: the sentinel survived an install onto its OWN disk — the untouched row above proves nothing"
        else
            ok "negative control: installing to the foreign disk destroys the sentinel (the untouched row fires)"
        fi
    fi
}
