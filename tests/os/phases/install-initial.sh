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
    : >"$SERIAL"
    # The image rides a USB bus with removable=on — that is what makes the guest a faithful
    # analog of a user's stick: the host-side gate (installer_mode_available) keys on
    # /sys/block/*/removable, which virtio never sets.
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed to define the installer VM"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 240 || {
        bad "installer guest never answered SSH (ip: ${ip:-none})"
        return 1
    }
    ok "image boots as removable media ($ip)"

    out=$(_ssh "pithead-install --list")
    if printf '%s' "$out" | cut -f1 | grep -qx "vda"; then
        ok "inventory offers the internal disk (vda)"
    else
        bad "inventory does not offer vda — got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
        return 1
    fi
    # The boot medium must never be a target. It shows up as sdX on the USB bus.
    if printf '%s' "$out" | cut -f1 | grep -qE '^sd'; then
        bad "inventory offers the boot medium itself"
        return 1
    fi
    ok "inventory excludes the disk the system booted from"
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
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$target_disk,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed to define the installed VM"
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

}
