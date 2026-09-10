# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
phase_reset() {
    info "phase: reset (factory-reset ESP marker + wedged-/data recovery — opt-in, destructive)"
    local img token tries jar scode names deadline

    info "leg 1 — factory-reset must wipe /data and return a FRESH machine to the wizard"
    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return
    }
    _vm_boot_disk "$img" && _wait_ssh 240 || {
        bad "guest never answered SSH (ip: ${ip:-none})"
        return
    }
    ok "image boots ($ip)"

    token="" tries=0
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token ever appeared on the console"
        return
    }
    _wait_setup_page 120 || {
        bad "wizard gate never served"
        return
    }

    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "token was not accepted"
        rm -f "$jar"
        return
    }
    scode=$(curl -sSk -b "$jar" --data "monero_wallet=$HARNESS_WALLET&tari_wallet=$HARNESS_TARI&pool=mini" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "config submit did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return
    }
    tries=0
    while [ "$tries" -lt 24 ]; do
        curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"' && break
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] || {
        bad "no credentials handoff appeared on the page"
        rm -f "$jar"
        return
    }
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    ok "config submitted and provisioning released"

    if ! _ssh "for i in \$(seq 120); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        bad "the submitted config never became /data/pithead/config.json"
        return
    fi
    ok "provisioned: config installed by the host"

    names="" deadline=$(($(date +%s) + 1500))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in
        *dashboard*caddy* | *caddy*dashboard*) break ;;
        esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*)
        ok "stack containers are running ahead of the reset ($names)"
        ;;
    *)
        bad "stack never came up before the reset — running: '${names:-none}'"
        stack_never_up_evidence # #2043: the guest is recycled next, so ask it now
        return
        ;;
    esac

    # Baseline, captured on the machine ABOUT to be wiped.
    local id_before fp_before images_before
    id_before=$(_ssh cat /etc/machine-id)
    fp_before=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    images_before=$(_ssh "podman images --format '{{.Repository}}'" 2>/dev/null | tr '\n' ' ')
    if [ -n "$id_before" ] && [ -n "$fp_before" ] && printf '%s' "$images_before" | grep -q dashboard; then
        ok "pre-reset baseline: machine-id $id_before, host-key $fp_before, images present ($images_before)"
    else
        bad "could not capture a full pre-reset baseline (id: ${id_before:-none}, fp: ${fp_before:-none}, images: ${images_before:-none})"
        return
    fi

    # The real command an operator runs — not a reimplementation of it (factory_reset() in
    # `pithead`). It arms the ESP marker and reboots; the ssh connection drops with the reboot.
    if _reboot_wait "cd /data/pithead && ./pithead factory-reset -y" 300; then
        ok "guest returned after the factory-reset reboot"
    else
        bad "guest never returned after factory-reset — BRICKED"
        return
    fi

    if _wait_setup_page 120; then
        ok "machine comes back UNPROVISIONED — the wizard token gate serves again"
    else
        bad "no wizard gate after factory-reset — the machine did not return to first-boot"
    fi
    if _ssh "test -f /data/pithead/config.json"; then
        bad "the provisioned config.json survived factory-reset"
    else
        ok "the provisioned config is gone"
    fi
    # #1092: a post-boot `test -d` here is true by construction, not a check of the reseed. The overlay/var +
    # var-work upperdirs cannot be observed missing at this point — with no `nofail` on that fstab line
    # (os/rauc/populate-slot.sh), a missing upperdir fails local-fs.target on this read-only root and the box
    # never answers SSH, so the leg would already have bailed above at "guest never returned after
    # factory-reset — BRICKED". And /data/pithead is recreated by pithead-sync's own `mkdir -p` on every boot
    # (os/overlay/pithead-sync) whether or not repart seeded it, so its presence here proves the sync script
    # ran, not that the seed worked. The seeding mechanism itself — systemd-repart's MakeDirectories= for all
    # three dirs — is asserted statically against the built image in tests/os/verify-image.sh, the one place
    # that can actually observe a dropped entry. What THIS leg proves is the pair above: the reformat+reboot
    # cycle didn't brick, and it landed back at an unprovisioned wizard. The dashboard image is BAKED into the
    # OS image (the wizard archive) and legitimately reloaded onto the fresh store by the post-reset wizard
    # boot — its presence proves nothing. The wipe probe is an image that only ever arrives by PULL at
    # provision time: monerod.
    local images_after
    images_after=$(_ssh "podman images --format '{{.Repository}}'" 2>/dev/null | tr '\n' ' ')
    if printf '%s' "$images_after" | grep -q monero; then
        bad "the OLD container store survived factory-reset (still has: $images_after)"
    else
        ok "container store was recreated — no pulled stack images survive the wipe (podman images: ${images_after:-none})"
    fi

    # The reset-tier rule (os/overlay/pithead-data-reset): /data/ssh and /data/pithead/machine-id
    # are deliberately NOT reseeded, so both regenerate — a handed-over box keeps nothing OF THE
    # OWNER'S. A bare inequality already caught one real bug (a dbus-baked machine-id shared by
    # every image, fixed in the rootfs Dockerfile) but cannot pass HERE even when the product is
    # right: with that bake gone, systemd's next first-boot source inside a VM is the DMI product
    # UUID (machine-id(5) — VM-only; real hardware falls through to random), and this leg reboots
    # ONE VM, so the "fresh" id is deterministically the same. The honest assert: the regenerated
    # id is the PLATFORM's (DMI-derived — machine identity, like a serial number) or it changed
    # (the real-hardware shape). Only an id that is neither proves owner state carried over.
    local id_after fp_after dmi_id
    id_after=$(_ssh cat /etc/machine-id)
    fp_after=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    dmi_id=$(_ssh "cat /sys/class/dmi/id/product_uuid 2>/dev/null" | tr -d '-' | tr 'A-F' 'a-f')
    if [ -n "$id_after" ] && { [ "$id_after" != "$id_before" ] || [ "$id_after" = "$dmi_id" ]; }; then
        ok "machine-id regenerated from the platform after factory-reset ($id_after${dmi_id:+, matches DMI})"
    else
        bad "machine-id survived factory-reset (before: $id_before, after: ${id_after:-none}, dmi: ${dmi_id:-none}) — the old owner's identity carried over"
    fi
    if [ -n "$fp_after" ] && [ "$fp_after" != "$fp_before" ]; then
        ok "SSH host-key fingerprint is FRESH after factory-reset ($fp_before -> $fp_after)"
    else
        bad "SSH host-key fingerprint survived factory-reset (before: $fp_before, after: ${fp_after:-none})"
    fi

    # ---- leg 2: a wedged /data must be REPAIRED, not erased --------------------------------
    info "leg 2 — a corrupt data-partition superblock must be repaired, with /data still there afterwards"
    # A sentinel standing in for what /data actually holds: the wallets, the Tor onion private keys,
    # the dashboard database and both synced chains. Until #1062 this leg asked only whether the box
    # came back to the wizard, which a full reformat satisfies — so a green battery certified the
    # data loss (#1087). The question is not "did it boot", it is "is the irreplaceable thing still
    # there". A reformat cannot pass this.
    _ssh "mkdir -p /data/pithead && printf 'IRREPLACEABLE-KEY-MATERIAL\n' > /data/pithead/.battery-sentinel && sync" || {
        bad "could not plant the /data survival sentinel"
        return
    }
    # Leg 1's factory reset was a REAL wipe and correctly recorded one, so the note already exists
    # here. What leg 2 must not do is add to it: the count is the question, not the presence.
    local wipes_before
    wipes_before=$(_ssh "wc -l < /boot/efi/pithead-data-wiped 2>/dev/null" | tr -cd '0-9')
    [ -n "$wipes_before" ] || wipes_before=0
    _ssh "systemctl poweroff" 2>/dev/null || true
    tries=0
    while [ "$tries" -lt 60 ]; do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] && break
        sleep 5
        tries=$((tries + 1))
    done
    [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] || {
        bad "guest never powered off cleanly before corrupting the data partition"
        return
    }

    # Corrupt the ext4 magic (2 bytes at offset 1080 — the 1024-byte superblock plus s_magic at
    # 0x38) on partition 4, the fixed data slot pithead-data-reset itself derives by number. Done
    # from the HOST against the powered-off disk, via a loop device with partition scanning:
    # dd'ing a MOUNTED filesystem's superblock risks the live kernel writing the correct bytes
    # straight back before the corruption is ever read at the next mount.
    local loopdev
    loopdev=$(losetup -f) || {
        bad "no free loop device to corrupt the data partition"
        return
    }
    if losetup -P "$loopdev" "$DISK"; then
        have udevadm && udevadm settle 2>/dev/null
        sleep 1
        if [ -b "${loopdev}p4" ] &&
            dd if=/dev/zero of="${loopdev}p4" bs=1 seek=1080 count=2 conv=notrunc >/dev/null 2>&1; then
            ok "corrupted the ext4 magic on the data partition (${loopdev}p4)"
        else
            bad "could not corrupt ${loopdev}p4 (partition node missing or dd failed)"
            losetup -d "$loopdev" 2>/dev/null || true
            return
        fi
    else
        bad "losetup -P failed to attach $DISK"
        return
    fi
    losetup -d "$loopdev" 2>/dev/null || true

    virsh start "$VM" >/dev/null 2>&1 || {
        bad "guest would not start after the corruption"
        return
    }
    if _wait_ssh 300; then
        ok "guest survived a wedged /data — no brick"
    else
        bad "BRICKED — no boot after a corrupt data-partition superblock (disqualifying)"
        return
    fi
    if _wait_setup_page 120; then
        ok "the box came back usable after the corrupt superblock"
    else
        bad "no wizard gate after the wedged-/data recovery — the box did not come back usable"
    fi
    # The assertion that a reformat cannot satisfy: `fsck -p` refuses a corrupt primary superblock,
    # so before #1062 this partition was handed to mkfs.ext4 -F and the sentinel died with it.
    if [ "$(_ssh "cat /data/pithead/.battery-sentinel 2>/dev/null" | tr -d '\r')" = "IRREPLACEABLE-KEY-MATERIAL" ]; then
        ok "/data SURVIVED the corrupt superblock — it was repaired, not erased (#1062)"
    else
        bad "DATA LOSS — /data was reinitialized rather than repaired; a real box loses its wallets and onion keys here (#1062)"
    fi
    # And the wipe log must not have grown: a repair is not a wipe, and evidence that cries wolf
    # is worse than none — the operator would restore from backup over a machine that kept its data.
    local wipes_after
    wipes_after=$(_ssh "wc -l < /boot/efi/pithead-data-wiped 2>/dev/null" | tr -cd '0-9')
    [ -n "$wipes_after" ] || wipes_after=0
    if [ "$wipes_after" = "$wipes_before" ]; then
        ok "the ESP wipe log did not grow ($wipes_before line(s), from leg 1's real factory reset) — a repair is not recorded as a wipe"
    else
        bad "a repaired /data recorded a wipe on the ESP ($wipes_before -> $wipes_after) — the evidence would cry wolf"
    fi
    # Leg 1's own wipe SHOULD be in there: the recording path is real, not dead code.
    if [ "$wipes_before" -gt 0 ] 2>/dev/null; then
        ok "leg 1's factory reset was recorded on the ESP ($wipes_before line(s))"
    else
        bad "leg 1 reformatted /data and left no record on the ESP — a wiped machine is indistinguishable from a fresh one (#1062)"
    fi
}
