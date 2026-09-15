# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_rigmedia_remove_target() { # <path> — retain evidence under --keep
    [ "$KEEP" -eq 1 ] || rm -f "$1"
}

_rigmedia_quiesce() { # stop the guest; --keep retains its definition and disks
    if [ "$KEEP" -eq 1 ]; then
        virsh destroy "$VM" >/dev/null 2>&1
    else
        vm_destroy_or_refuse
    fi
}

_rigmedia_fail_cleanup() { # <target> — retain a stopped inspectable guest under --keep
    local domains
    [ "$KEEP" -ne 1 ] || {
        domains=$(virsh list --all --name) || {
            bad "could not inspect the rigmedia VM for --keep"
            return 1
        }
        if grep -Fxq "$VM" <<<"$domains" && ! virsh destroy "$VM" >/dev/null 2>&1; then
            bad "could not quiesce the rigmedia VM for --keep"
            return 1
        fi
    }
    _rigmedia_remove_target "$1"
}

phase_rigmedia() {
    info "phase: rigmedia (M14, #1829 — a rig that boots the stick and never installs)"
    # The install phase's own boot shape (image on a removable USB bus, boot.order=1) beside a
    # blank internal disk — but here the internal disk is the thing under test BY STAYING BLANK:
    # a rig that answers RigForge must never touch it, unlike the install phase's own target.
    local img target_disk="/srv/code/bench-vm/pithead-rigmedia-target.img" token jar body scode card empty_before empty_after

    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return
    }
    vm_destroy_or_refuse || return
    rm -f "$target_disk"
    cp "$img" "$DISK"
    qemu-img resize "$DISK" 16G >/dev/null 2>&1 || {
        bad "could not size the removable-media disk"
        _rigmedia_fail_cleanup "$target_disk"
        return
    }
    qemu-img create -f raw "$target_disk" 30G >/dev/null
    empty_before=$(sha256sum "$target_disk" | cut -d' ' -f1)
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed to define the rigmedia VM"
        _rigmedia_fail_cleanup "$target_disk"
        return
    }
    _wait_dhcp_ip 120
    _wait_ssh 240 || {
        bad "rigmedia guest never answered SSH (ip: ${ip:-none})"
        _rigmedia_fail_cleanup "$target_disk"
        return
    }
    ok "image boots as removable media ($ip)"

    local tries=0
    token=""
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token ever appeared on the console"
        _rigmedia_fail_cleanup "$target_disk"
        return
    }
    _wait_setup_page 120 || {
        bad "wizard gate never served"
        _rigmedia_fail_cleanup "$target_disk"
        return
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "token was not accepted"
        rm -f "$jar"
        _rigmedia_fail_cleanup "$target_disk"
        return
    }

    # Same faked pool as the rig phase (#796): this leg is about the STICK, not the network — the
    # rig phase already carries the accepted-share gap. disk=usb is the wizard's own "run from
    # this stick" token (server.py's _submit_rig): the one disk value that is not an install
    # target, so no install-request is ever published (dashboard/tests/web's own coverage of the
    # same branch: test_run_from_this_stick_is_first_class_for_the_rig_role_only).
    body="role=rig&rig_pool=127.0.0.1:22&rig_worker=kvm-rigmedia&disk=usb"
    scode=$(curl -sSk -b "$jar" --data "$body" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "rig submit did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        _rigmedia_fail_cleanup "$target_disk"
        return
    }
    ok "rig role submitted through the wizard, no install offered"
    tries=0
    while [ "$tries" -lt 24 ]; do
        card=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        case "$card" in *'"worker"'*) break ;; esac
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] || {
        bad "no rig card appeared on the page"
        rm -f "$jar"
        _rigmedia_fail_cleanup "$target_disk"
        return
    }
    scode=$(curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "rig card acknowledgement did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        _rigmedia_fail_cleanup "$target_disk"
        return
    }
    rm -f "$jar"

    if _rig_mining_up 36; then
        ok "the rig mines from the stick (xmrig unit active, process running), no disk install"
    else
        bad "the rig never started mining from the stick (unit: $(_ssh 'systemctl is-active xmrig' 2>/dev/null || echo unknown))"
    fi
    if _ssh "cmp -s /data/rigforge/data/worker/xmrig/build/xmrig /opt/rigforge/prebuilt/xmrig/build/xmrig"; then
        ok "the stick-run rig mines the BAKED binary byte for byte"
    else
        bad "the running miner is not the baked prebuilt"
    fi
    local names
    names=$(_ssh "podman ps -a --format '{{.Names}}'" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    if [ -z "${names// /}" ]; then
        ok "no compose stack was started on the stick-run rig"
    else
        bad "a stick-run rig started containers: '$names'"
    fi
    [ "$(_ssh 'systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -c "^Storage=volatile"')" != "0" ] &&
        ok "journald is volatile on a stick-run rig" ||
        bad "journald is still persistent on a stick-run rig"

    info "reboot leg — the stick-run rig must come back mining, no hands"
    _reboot_wait reboot 300 || {
        bad "the stick-run rig never returned from the reboot"
        _rigmedia_fail_cleanup "$target_disk"
        return
    }
    _rig_mining_up 24 &&
        ok "the stick-run rig returned mining unaided after a reboot" ||
        bad "the stick-run rig did not return mining after the reboot"

    _rigmedia_quiesce || {
        return
    }
    empty_after=$(sha256sum "$target_disk" | cut -d' ' -f1)
    [ "$empty_after" = "$empty_before" ] &&
        ok "the empty target disk is still empty — a stick-run rig never touched it" ||
        bad "the target disk changed even though the rig never installed to it"
    _rigmedia_remove_target "$target_disk"
}
