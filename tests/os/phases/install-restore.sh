# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_phase_install_restore() {
    # ---- restore-at-setup leg (#909, #786 sub-issue B) -----------------------------------
    # A genuine encrypted backup pulled off a live, fully-provisioned machine seeds a
    # totally fresh disk through the wizard's upload path instead of the config form — the
    # disaster-recovery loop #908 (export) opens and this closes. Real archive, real upload
    # over curl -F, real decrypt+extract on the guest, and the identity (wallet, Tor onion)
    # must survive — proof the "restored config drives provisioning as if pre-seeded" promise
    # actually holds, which nothing below tier 4 can prove.
    #
    # The keep-reinstalled machine above sits at the WIZARD — a reinstall always returns
    # there (keep preserves /data, not provisioned-ness), and `pithead backup` rightly
    # refuses without a provisioned stack (.env, onion keys). Provision it first, through
    # the same HTTP flow a human would drive.
    local rtoken rjar rtries
    rtoken=""
    rtries=0
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
    # A keep-machine keeps its old login, so the credentials card (and the hold it creates)
    # may never appear — ack it if it does, move on if it does not.
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
        # Settle before backing up: `pithead backup` stops the RUNNING containers, but ones
        # still being created slip past that stop and start mid-tar — "file changed as we read
        # it" killed the pipeline once. Two identical readings 10s apart means startup is over.
        local rprev=""
        rtries=0
        while [ "$rtries" -lt 30 ]; do
            [ -n "$rnames" ] && [ "$rnames" = "$rprev" ] && break
            rprev="$rnames"
            sleep 10
            rnames=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
            rtries=$((rtries + 1))
        done
        ;;
    *)
        bad "restore leg: stack never came up after provisioning (running: '${rnames:-none}')"
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
        # The reason lives on the guest — capture ALL of it, log AND tree, or this failure is
        # undiagnosable after the VM is recycled (it has been, twice: #1059).
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
    vm_destroy

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
    # The combined leg: ONE upload carries the archive, its passphrase, AND the disk choice —
    # the same _gate_install_request every other installer submission takes.
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
    # Captured for the live-state check below (#1091) — the restored machine's OWN generated
    # login, not the source machine's, since a keep-reinstall would have kept the old one.
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
    vm_destroy
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
    # The carried restore lands during firstboot and .env only exists once render has run —
    # wait for provisioning, don't race it.
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
    # THE assertion this leg exists for (#1091): config.json landing on disk proves the archive
    # was UNPACKED — it is a grep of a file the restore itself just wrote, so it is true even if
    # the stack never came back up on the restored config. So wait for the stack to actually come
    # up, then require a value sourced from the restored config to appear in LIVE state: the
    # --wallet argument the stack's own start path rendered into the p2pool container, read off
    # the container as created (#1662: p2pool's stratum stats, the earlier source, exist only once
    # a SYNCED monerod hands it a block template, which a restored guest never has in this window).
    # The verdict (restore_live_state_verdict) is fixture-tested at tier 1 (tests/stack/run.sh).
    local rsnames="" live_wallet="" verdict
    local rsdeadline
    rsdeadline=$(($(date +%s) + 900))
    while [ "$(date +%s)" -lt "$rsdeadline" ]; do
        rsnames=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$rsnames" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
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
        # A stack that never came up won't answer the identity check below either — stop here
        # rather than burn its 600s timeout on a machine already known to be broken.
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
    phase_install_prefill_submit_leg "$target_disk" # #1846, last: nothing after it needs the disk
    rm -f "$target_disk" "$restore_archive" "$restore_target"
}
