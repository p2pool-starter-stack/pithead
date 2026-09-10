# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_phase_install_reinstall() {
    # ---- reinstall leg: the path that must NOT lose data --------------------------------
    # A disk that already carries a pithead layout is reinstalled in place; /data must survive.
    info "reinstall leg — a second install over the same disk must preserve /data"
    _ssh "echo chain-data-survives > /data/pithead/reinstall-sentinel &&
          mkdir -p /data/pithead/data/monero /data/pithead/data/tari &&
          echo synced-chain > /data/pithead/data/monero/chain-sentinel &&
          echo synced-chain > /data/pithead/data/tari/chain-sentinel &&
          tmp=\$(mktemp /data/pithead/.config.legacy.XXXXXX) &&
          jq '.xmrig_proxy={enabled:false} | del(.xvb)' /data/pithead/config.json >\"\$tmp\" &&
          chmod 600 \"\$tmp\" && mv \"\$tmp\" /data/pithead/config.json" || {
        bad "could not plant the reinstall sentinels and 1.x-shaped config"
        return 1
    }
    _ssh "systemctl poweroff" 2>/dev/null || true
    sleep 8
    vm_destroy
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    # shellcheck disable=SC2154  # target_disk is local to phase_install via dynamic scope
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed for the reinstall boot"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 240 || {
        bad "installer guest never answered SSH for the reinstall leg"
        return 1
    }
    if _ssh "pithead-install --list" | grep -q "pithead-with-data"; then
        ok "inventory recognises the installed disk (pithead-with-data)"
    else
        bad "inventory does not flag the installed disk as carrying data"
    fi
    # ---- reinstall pre-fill: previous answers and removed aliases, never secrets --------
    # Pair the page state with this boot's own pre-fill log; #1038 proved a matching wallet alone
    # cannot identify the producer. This runs before the wipe legs destroy the source config.
    token=""
    tries2=0
    while [ -z "$token" ] && [ "$tries2" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries2=$((tries2 + 1))
    done
    if [ -n "$token" ] && _wizard_up; then
        jar=$(mktemp)
        local pf_state="" branch_logged=0 wallet_prefilled=0 password_leaked=0 pf_verdict
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
            pf_state=$(curl -fsSk -b "$jar" "https://$ip/api/wizard-state" 2>/dev/null)
        rm -f "$jar"
        grep -qF "Found the previous installation's settings on the target disk" "$SERIAL" &&
            branch_logged=1
        printf '%s' "$pf_state" | grep -q "\"wallet_address\": \"${HARNESS_WALLET:0:8}" &&
            wallet_prefilled=1
        # The provisioned config held a generated dashboard password; it must stay stripped.
        printf '%s' "$pf_state" | grep -Eq '"password": "[^"]' && password_leaked=1
        if pf_verdict=$(reinstall_prefill_verdict "$branch_logged" "$wallet_prefilled" "$password_leaked"); then
            ok "$pf_verdict"
        else
            bad "$pf_verdict"
        fi
        if printf '%s' "$pf_state" | jq -e '
            .config.xvb.enabled == false and (.config | has("xmrig_proxy") | not) and
            (.config_changes | index("xmrig_proxy.enabled → xvb.enabled"))' >/dev/null; then
            ok "reinstall pre-fill migrates the removed xmrig_proxy key to xvb"
        else
            bad "reinstall pre-fill kept or dropped the removed 1.x XvB setting instead of migrating it"
        fi
    else
        bad "no wizard session for the pre-fill check (token: ${token:-none})"
    fi
    # ---- wipe legs: the three-way reinstall data choice, asserted on the raw partition ----
    # Mounted from the installer VM (the target's data partition is vda4) rather than booting
    # between legs — the assertion is about what is ON the disk, and this keeps three slot
    # copies instead of three full boot cycles.
    info "wipe=data — user data goes, the synced chains stay"
    out=$(_ssh "pithead-install --target /dev/vda --wipe data --yes 2>&1")
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -q "preserving the synced chains"; then
        ok "wipe=data took the selective path"
    else
        bad "wipe=data failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-140)"
        return 1
    fi
    # The mountpoint comes from mktemp: the appliance root is READ-ONLY, so a path like /mnt/t
    # cannot be created — mkdir's refusal was eaten by _ssh's stderr drop and read as a wipe bug.
    local wout
    wout=$(_ssh "T=\$(mktemp -d) && mount /dev/vda4 \"\$T\" 2>&1 || { echo MOUNT-FAILED; exit 9; }
                 s=OK
                 test -s \"\$T/pithead/data/monero/chain-sentinel\" || s=NO-MONERO-CHAIN
                 test -s \"\$T/pithead/data/tari/chain-sentinel\" || s=\$s,NO-TARI-CHAIN
                 test -e \"\$T/pithead/reinstall-sentinel\" && s=\$s,USER-DATA-SURVIVED
                 umount \"\$T\" 2>&1 || s=\$s,UMOUNT-FAILED
                 echo \"verdict=\$s\"" 2>&1)
    # Anchored: "verdict=OK,USER-DATA-SURVIVED" must NOT pass — the suffix flags are the failure.
    if printf '%s' "$wout" | grep -qx "verdict=OK"; then
        ok "wipe=data KEPT both chains and dropped the user data"
    else
        bad "wipe=data got the split wrong: $(printf '%s' "$wout" | tr '\n' ' ' | cut -c1-300)"
        return 1
    fi
    info "wipe=all — the data partition is reformatted"
    _ssh "umount -A /dev/vda4 2>/dev/null || true"
    out=$(_ssh "pithead-install --target /dev/vda --wipe all --yes 2>&1")
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -q "everything, chains included"; then
        ok "wipe=all took the reformat path"
    else
        bad "wipe=all failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-140) [mounts: $(_ssh "findmnt -no SOURCE,TARGET | grep vda" | tr '\n' ' ')]"
        return 1
    fi
    if _ssh "T=\$(mktemp -d) && mount /dev/vda4 \"\$T\" && [ -z \"\$(ls \"\$T\" | grep -v lost+found)\" ]; rc=\$?; umount \"\$T\"; exit \$rc"; then
        ok "wipe=all left an empty data partition"
    else
        bad "wipe=all left residue on the data partition"
        return 1
    fi
    # Re-plant the keep-leg sentinel on the now-empty partition, then prove the DEFAULT path.
    _ssh "T=\$(mktemp -d) && mount /dev/vda4 \"\$T\" && mkdir -p \"\$T/pithead\" &&
          echo chain-data-survives > \"\$T/pithead/reinstall-sentinel\" && umount \"\$T\"" || {
        bad "could not re-plant the sentinel for the keep leg"
        return 1
    }
    _ssh "umount -A /dev/vda4 2>/dev/null || true"
    # A keep-reinstall must refresh the CONTAINERS too (#798). Model the machine that hit this
    # live: /data already carries a dashboard image under the release tag, with its digest
    # recorded beside the store — then reinstall from a NEWER stick. Only the digest-keyed
    # boot loader makes the image change; a tag-exists check keeps the old containers forever.
    info "keep leg prep — plant this build's dashboard image + digest record (a machine that ran it)"
    local old_dash_id=""
    # The plant must leave a store a REAL machine could have written. `podman --root` also
    # creates a libpod database (db.sql + libpod/) that records the mount path as the graph
    # root — and podman refuses a store whose recorded paths differ from its own, so the
    # reinstalled machine's every podman command died with "database configuration mismatch"
    # (invisible: _ssh drops stderr). A machine that ran the product wrote its db against
    # /data/containers/storage; dropping the plant's db models that machine — the first real
    # boot recreates it against the right paths, images intact.
    old_dash_id=$(_ssh "T=\$(mktemp -d) && mount /dev/vda4 \"\$T\" &&
          mkdir -p \"\$T/pithead/data\" \"\$T/containers/storage\" &&
          podman --root \"\$T/containers/storage\" load -qi /opt/pithead/images/dashboard.tar.gz >/dev/null &&
          sha256sum /opt/pithead/images/dashboard.tar.gz | cut -d' ' -f1 | tr -d '\n' >\"\$T/pithead/data/.loaded-dashboard.tar.gz.sha\" &&
          podman --root \"\$T/containers/storage\" images --format '{{.Repository}} {{.ID}}' | awk '/pithead-dashboard/{print \$2; exit}' &&
          rm -rf \"\$T/containers/storage/db.sql\" \"\$T/containers/storage/libpod\" &&
          umount \"\$T\"")
    [ -n "$old_dash_id" ] || {
        bad "could not plant the old dashboard image for the keep leg"
        return 1
    }
    ok "planted the old dashboard image ($old_dash_id) and its digest record on the target's /data"
    _ssh "systemctl poweroff" 2>/dev/null || true
    sleep 8
    vm_destroy
    info "building the NEWER stick (marker v2 — its dashboard archive differs)"
    img=$(_build_image v2) || {
        bad "v2 stick build failed (/tmp/os-fault-build.log)"
        return 1
    }
    cp "$img" "$DISK"
    qemu-img resize "$DISK" 16G >/dev/null 2>&1 || true
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    # shellcheck disable=SC2154  # target_disk is local to phase_install via dynamic scope
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed for the newer-stick keep-reinstall boot"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 240 || {
        bad "newer stick never answered SSH for the keep leg"
        return 1
    }
    ok "newer stick boots as removable media"
    _ssh "for i in \$(seq 36); do [ -s /data/pithead/data/firstboot/disks.tsv ] && exit 0; sleep 5; done; exit 1" || {
        bad "the newer stick never published a disk inventory"
        return 1
    }
    # The keep path goes through the PAGE, exactly as an operator would: a bare submit with the
    # disk and wipe=keep — no config, because the survivor config wins. No credentials card may
    # appear (the machine keeps its old login; a regenerated one here was a real bench bug).
    token=""
    tries2=0
    while [ -z "$token" ] && [ "$tries2" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries2=$((tries2 + 1))
    done
    [ -n "$token" ] || {
        bad "no token for the keep-reinstall leg"
        return 1
    }
    # Fresh boot: the token prints before the wizard container finishes coming up.
    _wait_setup_page 180 || {
        bad "the newer stick's wizard never served its gate page"
        return 1
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "keep-reinstall auth failed"
        rm -f "$jar"
        return 1
    }
    scode=$(curl -sSk -b "$jar" --data "disk=vda&confirm=vda&wipe=keep" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "keep-reinstall submit did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return 1
    }
    sleep 3
    hcode=$(curl -sSk -b "$jar" -o /dev/null -w '%{http_code}' -m 5 "https://$ip/api/handoff" 2>/dev/null)
    if [ "$hcode" = "404" ]; then
        ok "keep-reinstall shows NO credentials card — the machine keeps its old login"
    else
        bad "a handoff appeared on a keep reinstall (HTTP $hcode) — its password would be a lie"
    fi
    rm -f "$jar"
    tries2=0
    while [ "$tries2" -lt 60 ]; do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] && break
        sleep 5
        tries2=$((tries2 + 1))
    done
    if [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ]; then
        ok "keep-reinstall installed and switched itself off"
    else
        bad "keep-reinstall never powered off"
        return 1
    fi
    vm_destroy
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    # shellcheck disable=SC2154  # target_disk is local to phase_install via dynamic scope
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$target_disk,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed for the reinstalled system"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 300 || {
        bad "reinstalled system never answered SSH"
        return 1
    }
    ok "reinstalled system boots"
    if [ "$(_ssh cat /data/pithead/reinstall-sentinel)" = "chain-data-survives" ]; then
        ok "REINSTALL PRESERVED /data — the sentinel survived"
    else
        bad "REINSTALL LOST /data — the sentinel is gone (this is the chain-eating bug)"
    fi
    if _ssh "test -s /var/lib/dpkg/status"; then
        ok "reinstalled system copy is complete"
    else
        bad "/var/lib/dpkg/status missing after reinstall"
    fi
    if _wizard_up; then
        ok "wizard serves after the reinstall"
    else
        bad "no wizard on :80 after the reinstall"
    fi
    # The keep-leg staleness assertions (#798): the dashboard image ID must have CHANGED — the
    # boot-path loader keyed on the newer stick's archive digest, over a /data that already
    # held the old image under the same tag — and the page actually served must come from the
    # new image, not merely "some wizard answers".
    local new_dash_id dm
    new_dash_id=$(_ssh "podman images --format '{{.Repository}} {{.ID}}'" | awk '/pithead-dashboard/{print $2; exit}')
    if [ -n "$new_dash_id" ] && [ "$new_dash_id" != "$old_dash_id" ]; then
        ok "KEEP-REINSTALL REFRESHED THE DASHBOARD IMAGE ($old_dash_id -> $new_dash_id)"
    else
        bad "keep-reinstall left the old dashboard image in place (id: ${new_dash_id:-none}, was $old_dash_id)"
    fi
    if dm=$(_dash_marker_served v2 300); then
        ok "the served page comes from the NEWER stick's dashboard image"
    else
        bad "the reinstalled machine still serves the old dashboard image (got: $dm)"
    fi

}
