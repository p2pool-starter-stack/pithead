# shellcheck shell=bash
# shellcheck disable=SC2154
: "${OS_RUN_SUITE:?source via the suite runner}"
_phase_install_rig_verdict() {
    jq -e --arg token "$1" '
        ($token | test("^[0-9a-f]{32}$")) and
        .rig.access_token == $token and .miner.ACCESS_TOKEN == $token and
        .rig.worker == "kvm-installed-rig" and .rig.pool == "127.0.0.1:22" and
        .miner.pools[0].user == .rig.worker and .miner.pools[0].url == .rig.pool and
        .role == "rig" and .root == "vda" and .esp_root == "vda" and
        .esp_type == "vfat" and .active == "active" and
        (.pid | test("^[1-9][0-9]*$")) and
        .containers == "" and .coordinator == "absent" and .seed == "absent"
    ' >/dev/null 2>&1
}
_phase_install_rig() {
    info "phase: RigForge installer to internal disk (#3076)"
    img=$(_build_image v1 rc3) || {
        bad "rig installer image build failed"
        return 1
    }
    vm_destroy_or_refuse || return 1
    if ! { rm -f "$target_disk" && cp "$img" "$DISK" &&
        qemu-img resize "$DISK" 16G >/dev/null &&
        qemu-img create -f raw "$target_disk" 30G >/dev/null; }; then
        bad "could not prepare the rig installer and internal disk"
        return 1
    fi
    : >"$SERIAL"
    kvm_preflight || return 1
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "could not boot the rig installer with an internal target"
        return 1
    }
    if ! { _wait_dhcp_ip 120 && _wait_ssh 240 && _wait_setup_page 180; }; then
        bad "rig installer did not serve its setup page"
        return 1
    fi
    local token="" jar="" card="" card_token="" n code
    for ((n = 0; n < 40; n++)); do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] && break
        sleep 3
    done
    [ -n "$token" ] || {
        bad "rig installer console token missing"
        return 1
    }
    jar=$(mktemp)
    if ! curl -fsSk -m 20 -c "$jar" --data-urlencode "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null ||
        ! grep -q wizard_session "$jar"; then
        rm -f "$jar"
        bad "rig installer authentication failed"
        return 1
    fi
    code=$(curl -sSk -m 30 -b "$jar" --data 'role=rig&rig_pool=127.0.0.1:22&rig_worker=kvm-installed-rig&disk=vda&confirm=vda&wipe=keep' \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    if [ "$code" != 200 ]; then
        rm -f "$jar"
        bad "rig installer combined role/disk submission refused"
        return 1
    fi
    for ((n = 0; n < 24; n++)); do
        card=$(curl -fsSk -m 5 -b "$jar" "https://$ip/api/handoff" 2>/dev/null) || card=""
        card_token=$(printf '%s' "$card" | jq -er '
            select(.role == "rig" and .worker == "kvm-installed-rig" and
                .stratum == "stratum+tcp://127.0.0.1:22" and (has("password") | not)) |
            .token | select(type == "string" and test("^[0-9a-f]{32}$"))' 2>/dev/null) || card_token=""
        [ -n "$card_token" ] && break
        sleep 5
    done
    if [ -z "$card_token" ]; then
        rm -f "$jar"
        bad "rig installer did not publish the token-bearing rig card"
        return 1
    fi
    if ! curl -fsSk -m 20 -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null; then
        rm -f "$jar"
        bad "rig installer card acknowledgement failed"
        return 1
    fi
    rm -f "$jar"
    for ((n = 0; n < 90; n++)); do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = 'shut off' ] && break
        sleep 5
    done
    [ "$n" -lt 90 ] || {
        bad "rig installer did not finish and power off"
        return 1
    }
    ok "rig installer accepted role and internal disk together, published its card and powered off (#3076)"
    vm_destroy_or_refuse || return 1
    : >"$SERIAL"
    kvm_preflight || return 1
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$target_disk,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "could not boot the installed rig without its USB stick"
        return 1
    }
    if ! { _wait_dhcp_ip 120 && _wait_ssh 300; }; then
        bad "installed rig did not answer SSH"
        return 1
    fi
    local snapshot=""
    for ((n = 0; n < 60; n++)); do
        # shellcheck disable=SC2016
        snapshot=$(_ssh 'set -e
            containers=$(podman ps -aq)
            jq -n --slurpfile rig /data/pithead/rig.json --slurpfile miner /data/rigforge/config.json \
                --arg role "$(cat /data/pithead/machine-role)" \
                --arg root "$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)" \
                --arg esp_root "$(lsblk -no PKNAME "$(findmnt -n -M /boot/efi -o SOURCE)" | head -1)" \
                --arg esp_type "$(findmnt -n -M /boot/efi -o FSTYPE)" \
                --arg active "$(systemctl is-active xmrig)" \
                --arg pid "$(pgrep -xo xmrig)" --arg containers "$containers" \
                --arg coordinator "$(test ! -e /data/pithead/config.json && printf absent)" \
                --arg seed "$(test ! -e /boot/efi/pithead-rig.json && printf absent)" \
                "{rig:\$rig[0],miner:\$miner[0],role:\$role,root:\$root,active:\$active,pid:\$pid,
                  esp_root:\$esp_root,esp_type:\$esp_type,containers:\$containers,coordinator:\$coordinator,seed:\$seed}"' 2>/dev/null) || snapshot=""
        if printf '%s' "$snapshot" | _phase_install_rig_verdict "$card_token"; then
            ok "internal-disk rig retains the card token, runs XMRig without containers and scrubs the ESP seed (#3076)"
            return 0
        fi
        sleep 5
    done
    bad "installed rig failed token, disk, miner, no-stack or ESP-scrub assertions (#3076)"
    return 1
}
