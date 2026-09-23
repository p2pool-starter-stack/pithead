# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_restore_target_preboot_verdict() { # <powered-off target image>
    local disk="$1" loop esp="" data="" mnt tries=0 rc=0
    loop=$(losetup -Pf --show "$disk") || {
        bad "restore leg: could not inspect the installed disk before its first boot"
        return 1
    }
    udevadm settle 2>/dev/null || true
    while [ "$tries" -lt 50 ]; do
        esp=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk '$2 == "esp" {print $1; exit}')
        data=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk '$2 == "data" {print $1; exit}')
        [ -b "$esp" ] && [ -b "$data" ] && break
        sleep 0.1
        tries=$((tries + 1))
    done
    mnt=$(mktemp -d)
    if [ -b "$esp" ] && mount -o ro "$esp" "$mnt"; then
        if [ ! -e "$mnt/pithead-restore.enc" ] && [ ! -e "$mnt/pithead-restore-pass" ] &&
            [ ! -e "$mnt/pithead-config.json" ] && [ ! -e "$mnt/pithead-token.txt" ] && [ ! -e "$mnt/pithead-rig.json" ]; then
            ok "restore leg: no restore or unrelated pre-seed credential persisted on the target ESP before first boot"
        else
            bad "restore leg: restore carry persisted on the target ESP before first boot"
            rc=1
        fi
        umount "$mnt"
    else
        bad "restore leg: could not inspect the target ESP before first boot"
        rc=1
    fi
    if [ -b "$data" ] && mount -o ro "$data" "$mnt"; then
        if [ -f "$mnt/pithead/config.json" ] && [ -f "$mnt/pithead/.restore-pending" ] &&
            [ ! -e "$mnt/pithead/.restore-incomplete" ] &&
            [ -z "$(find "$mnt" \( -name pithead-restore-pass -o -name pithead-restore.enc \) -print -quit)" ]; then
            ok "restore leg: validated state and only a non-secret handoff marker reached target data"
        else
            bad "restore leg: validated state did not reach target data before first boot"
            rc=1
        fi
        umount "$mnt"
    else
        bad "restore leg: could not inspect target data before first boot"
        rc=1
    fi
    rmdir "$mnt"
    losetup -d "$loop"
    return "$rc"
}

_restore_installer_preboot_verdict() { # <powered-off installer image>
    local disk="$1" loop esp="" data="" mnt tries=0 rc=0
    loop=$(losetup -Pf --show "$disk") || return 1
    udevadm settle 2>/dev/null || true
    while [ "$tries" -lt 50 ]; do
        esp=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk '$2 == "esp" {print $1; exit}')
        data=$(lsblk -lnpo NAME,PARTLABEL "$loop" | awk '$2 == "data" {print $1; exit}')
        [ -b "$esp" ] && [ -b "$data" ] && break
        sleep 0.1
        tries=$((tries + 1))
    done
    mnt=$(mktemp -d)
    if [ -b "$data" ] && mount -o ro "$data" "$mnt"; then
        if [ -z "$(find "$mnt/pithead" \( -name config.json -o -name handoff.json -o -name '*restore*pass*' -o -name '*restore*archive*' -o -name pithead-restore.enc -o -name restore-inflight \) -print -quit 2>/dev/null)" ]; then
            ok "restore leg: the powered-off installer medium retained no restore credentials"
        else
            bad "restore leg: the powered-off installer medium retained restore credentials"
            rc=1
        fi
        umount "$mnt"
    else
        bad "restore leg: could not inspect installer data after shutdown"
        rc=1
    fi
    if [ -b "$esp" ] && mount "$esp" "$mnt"; then
        # The pre-seeds are this leg's fixture: cleared once seen, or they outrank the next leg's reinstall pre-fill.
        if [ -f "$mnt/pithead-config.json" ] && [ -f "$mnt/pithead-token.txt" ] && [ -f "$mnt/pithead-rig.json" ] &&
            rm -f "$mnt/pithead-config.json" "$mnt/pithead-token.txt" "$mnt/pithead-rig.json"; then
            ok "restore leg: unrelated fleet pre-seeds returned only to the installer medium"
        else
            bad "restore leg: installer fleet pre-seeds were not restored after the install, or could not be cleared"
            rc=1
        fi
        umount "$mnt"
    else
        bad "restore leg: could not inspect installer pre-seeds after shutdown"
        rc=1
    fi
    rmdir "$mnt"
    losetup -d "$loop"
    return "$rc"
}

_phase_install_restore() {
    local rtoken="" rjar rtries=0
    while [ -z "$rtoken" ] && [ "$rtries" -lt 40 ]; do
        rtoken=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$rtoken" ] || sleep 3
        rtries=$((rtries + 1))
    done
    if [ -z "$rtoken" ]; then
        bad "restore leg: no wizard token on the console after the keep-reinstall"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk"
        return 1
    fi
    rjar=$(mktemp)
    # shellcheck disable=SC2154  # shared through the assembled runner scope
    curl -fsSk -c "$rjar" -d "token=$rtoken" "https://$ip/auth" -o /dev/null 2>/dev/null
    scode=$(curl -sSk -b "$rjar" --data "monero_wallet=$HARNESS_WALLET&tari_wallet=$HARNESS_TARI&pool=mini" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    if [ "$scode" != "200" ]; then
        bad "restore leg: wizard submit did not return 200 (got ${scode:-none})"
        rm -f "$rjar" "$target_disk"
        return 1
    fi
    rtries=0
    while [ "$rtries" -lt 12 ]; do
        if curl -sSk -b "$rjar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"'; then
            curl -sSk -b "$rjar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
            break
        fi
        sleep 5
        rtries=$((rtries + 1))
    done
    rm -f "$rjar"
    local rdeadline rnames
    rdeadline=$(($(date +%s) + 1500))
    rnames=""
    while [ "$(date +%s)" -lt "$rdeadline" ]; do
        rnames=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$rnames" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$rnames" in
    *dashboard*caddy* | *caddy*dashboard*)
        ok "restore leg: keep-reinstalled machine provisioned — a live stack to back up ($rnames)"
        if ! provisioning_settled 900; then
            bad "restore leg: provisioning never finished on the machine ($(provisioning_state))"
            backup_failure_evidence
            rm -f "$target_disk"
            return
        fi
        ok "restore leg: provisioning finished ($(provisioning_state))"
        ;;
    *)
        bad "restore leg: stack never came up after provisioning (running: '${rnames:-none}')"
        stack_never_up_evidence # #2043: the guest is recycled next, so ask it now
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk"
        return 1
        ;;
    esac
    local restore_archive="/tmp/pithead-os-restore-test.tar.gz.enc"
    local restore_pass="pithead-os-restore-test-passphrase" # fixture value, not real secret material
    rm -f "$restore_archive"
    backup_precapture # #1059: state of both collected files, plus a watcher for the run itself
    if _ssh "cd /data/pithead && PITHEAD_BACKUP_PASSPHRASE=$restore_pass ./pithead backup -y >/tmp/restore-backup.log 2>&1"; then
        ok "restore leg: took a real encrypted backup off the live machine"
        backup_watch_report # a vanish the backup happened to survive is still the #1059 event
    else
        bad "restore leg: could not take the source backup"
        backup_failure_evidence
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk"
        return 1
    fi
    local remote_archive
    remote_archive=$(_ssh "ls /data/pithead/backups/pithead-backup-*.tar.gz.enc" | tail -1)
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "root@$ip:$remote_archive" "$restore_archive" || {
        bad "restore leg: could not pull the backup archive off the guest"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk"
        return 1
    }
    local orig_onion
    orig_onion=$(_ssh "grep MONERO_ONION_ADDRESS /data/pithead/.env" | cut -d= -f2)
    _ssh "systemctl poweroff" 2>/dev/null || true
    sleep 8
    vm_destroy_or_refuse || return

    local restore_target="/srv/code/bench-vm/pithead-restore-target.img"
    rm -f "$restore_target"
    qemu-img create -f raw "$restore_target" 30G >/dev/null
    img=$(_build_image v1) || {
        bad "restore leg: image build failed"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    cp "$img" "$DISK"
    qemu-img resize "$DISK" 16G >/dev/null 2>&1 || true
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$restore_target,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "restore leg: virt-install failed for the fresh installer boot"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 240 || {
        bad "restore leg: installer guest never answered SSH"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    _ssh "for i in \$(seq 36); do [ -s /data/pithead/data/firstboot/disks.tsv ] && exit 0; sleep 5; done; exit 1" || {
        bad "restore leg: installer never reached installer mode"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    token=""
    tries2=0
    while [ -z "$token" ] && [ "$tries2" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries2=$((tries2 + 1))
    done
    [ -n "$token" ] || {
        bad "restore leg: no one-time token on the installer console"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    _wait_setup_page 120 || {
        bad "restore leg: wizard never served its gate page"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "restore leg: auth failed"
        rm -f "$jar" "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    _ssh "mount -o remount,rw /boot/efi 2>/dev/null || true; printf '%s' '{\"fixture\":\"fleet-config-secret\"}' >/boot/efi/pithead-config.json; printf '%s' 'pit-FLEET1' >/boot/efi/pithead-token.txt; printf '%s' '{\"access_token\":\"0123456789abcdef0123456789abcdef\",\"stratum_password\":\"fleet-rig-secret\"}' >/boot/efi/pithead-rig.json; chmod 600 /boot/efi/pithead-config.json /boot/efi/pithead-token.txt /boot/efi/pithead-rig.json" || {
        bad "restore leg: could not seed unrelated installer credentials"
        rm -f "$jar" "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    scode=$(curl -sSk -b "$jar" \
        -F "archive=@$restore_archive" -F "passphrase=$restore_pass" \
        -F "disk=vda" -F "confirm=vda" -F "wipe=keep" \
        "https://$ip/submit-restore" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "restore leg: upload did not return 200 (got ${scode:-none})"
        rm -f "$jar" "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    ok "restore leg: uploaded the backup archive instead of the form"
    local rhandoff=""
    tries2=0
    while [ "$tries2" -lt 24 ]; do
        rhandoff=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        printf '%s' "$rhandoff" | grep -q '"password"' && break
        sleep 5
        tries2=$((tries2 + 1))
    done
    [ "$tries2" -lt 24 ] || {
        bad "restore leg: no credentials card after the restore — the restored config never drove provisioning"
        rm -f "$jar" "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    ok "restore leg: the restored config drove provisioning to a credentials card"
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    DASH_USER=$(printf '%s' "$rhandoff" | jq -r '.username // "admin"')
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    DASH_PASS=$(printf '%s' "$rhandoff" | jq -r '.password // ""')
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    tries2=0
    while [ "$tries2" -lt 60 ]; do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] && break
        sleep 5
        tries2=$((tries2 + 1))
    done
    if [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ]; then
        ok "restore leg: installed and switched itself off"
    else
        bad "restore leg: never powered off after the ack"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    fi
    vm_destroy_or_refuse || return
    _restore_target_preboot_verdict "$restore_target" || {
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    _restore_installer_preboot_verdict "$DISK" || {
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$restore_target,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "restore leg: virt-install failed for the restored machine"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 300 || {
        bad "restore leg: restored machine never answered SSH"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    }
    ok "restore leg: the restored machine boots from the fresh disk"
    if _ssh "for i in \$(seq 90); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        ok "restore leg: the carried archive provisioned the machine — config.json is back"
    else
        bad "restore leg: no config.json ever appeared — the carried restore never landed"
        # shellcheck disable=SC2154  # shared through the assembled runner scope
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return 1
    fi
    if _ssh "grep -q \"$HARNESS_WALLET\" /data/pithead/config.json"; then
        ok "restore leg: restored machine carries the ORIGINAL wallet address, not a fresh one"
    else
        bad "restore leg: restored machine's config does not carry the original wallet"
    fi
    local rswait=900
    if provisioning_settled 900; then
        ok "restore leg: provisioning finished on the RESTORED machine ($(provisioning_state))"
    else
        bad "restore leg: provisioning never settled on the restored machine ($(provisioning_state))"
        rswait=0
    fi
    local rsnames="" live_wallet="" verdict
    local rsdeadline
    rsdeadline=$(($(date +%s) + rswait))
    while :; do
        rsnames=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$rsnames" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        [ "$(date +%s)" -lt "$rsdeadline" ] || break
        sleep 15
    done
    case "$rsnames" in
    *dashboard*caddy* | *caddy*dashboard*)
        local lwdeadline
        lwdeadline=$(($(date +%s) + 180))
        while [ "$(date +%s)" -lt "$lwdeadline" ]; do
            live_wallet=$(_ssh "podman inspect p2pool --format '{{json .Config.Cmd}}'" 2>/dev/null | jq -r 'index("--wallet") as $i | if $i == null then "" else .[$i+1] // "" end')
            [ -n "$live_wallet" ] && [ "$live_wallet" != "Unknown" ] && [ "$live_wallet" != "null" ] && break
            sleep 10
        done
        ;;
    esac
    if verdict=$(restore_live_state_verdict "$rsnames" "$live_wallet" "$HARNESS_WALLET"); then
        ok "restore leg: $verdict"
    else
        bad "restore leg: $verdict"
        stack_never_up_evidence # #2043: the guest is recycled next, so ask it now
        case "$rsnames" in
        *dashboard*caddy* | *caddy*dashboard*) ;;
        *)
            # shellcheck disable=SC2154  # shared through the assembled runner scope
            rm -f "$target_disk" "$restore_archive" "$restore_target"
            return 1
            ;;
        esac
    fi
    local new_onion="" tor_hostname=""
    local odeadline
    odeadline=$(($(date +%s) + 600))
    while [ "$(date +%s)" -lt "$odeadline" ]; do
        new_onion=$(_ssh "grep MONERO_ONION_ADDRESS /data/pithead/.env 2>/dev/null" | cut -d= -f2 | tr -d '\r')
        tor_hostname=$(_ssh "podman exec tor cat /var/lib/tor/monero/hostname 2>/dev/null" | tr -d '\r')
        [ -n "$new_onion" ] && [ -n "$tor_hostname" ] && break
        sleep 15
    done
    # .env is an archive member load_preserved_state replays verbatim when non-empty (pithead:6155-6166),
    # so new_onion == orig_onion proves only that the CONFIG FILE made the round trip — true even when
    # the Tor data dir (the onion PRIVATE KEYS) was dropped and Tor mints a fresh service underneath
    # (#1090). Only Tor's OWN hostname file, from the restored key material, proves the keys came back.
    if [ -n "$new_onion" ] && [ -n "$tor_hostname" ] && [ "$new_onion" = "$orig_onion" ] && [ "$tor_hostname" = "$orig_onion" ]; then
        ok "restore leg: restored machine kept the ORIGINAL Tor identity, not a regenerated one"
    else
        bad "restore leg: onion identity not restored (.env: $orig_onion -> ${new_onion:-none}, Tor's own hostname: ${tor_hostname:-none})"
    fi
    phase_install_prefill_submit_leg "$target_disk" || return # #1846, last: nothing after it needs the disk
    rm -f "$target_disk" "$restore_archive" "$restore_target"
}
