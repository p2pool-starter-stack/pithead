# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
_make_media_stick() {
    (
        local path="$1" json="$2" loop="" mnt="" backing="" source="" rc mount_rc tries=0 step="image creation"
        trap '
            rc=$?
            trap - EXIT
            if [ -n "$loop" ] && { ! backing=$(timeout -k 5 10 losetup --list --noheadings --output BACK-FILE "$loop") || [ "$backing" != "$path" ]; }; then
                printf "media fixture failed: cleanup ownership unverified; resources retained\n" >&2
                exit 2
            fi
            if [ -n "$mnt" ]; then
                mount_rc=0
                source=$(timeout -k 5 10 findmnt --mountpoint "$mnt" --noheadings --output SOURCE) || mount_rc=$?
                case "$mount_rc:$source" in
                "0:${loop}p1")
                    timeout -k 5 10 umount "$mnt" || {
                        printf "media fixture failed: unmount; resources retained\n" >&2
                        exit 2
                    }
                    ;;
                1:) ;;
                *)
                    printf "media fixture failed: mount ownership unverified; resources retained\n" >&2
                    exit 2
                    ;;
                esac
                rmdir "$mnt" || rc=2
            fi
            if [ -n "$loop" ]; then
                timeout -k 5 10 losetup -d "$loop" || rc=2
            fi
            [ "$rc" -eq 0 ] || printf "media fixture failed: %s\n" "$step" >&2
            exit "$rc"
        ' EXIT
        trap 'exit 2' HUP INT TERM
        rm -f "$path" || exit 2
        truncate -s 64M "$path" || exit 2
        path=$(readlink -f "$path") || exit 2
        step="partition table"
        timeout -k 5 10 sgdisk -n1:0:0 -t1:0700 "$path" >/dev/null || exit 2
        step="loop attachment"
        loop=$(timeout -k 5 10 losetup -Pf --show "$path") || exit 2
        [ -n "$loop" ] || exit 2
        step="partition readiness after 5 seconds"
        while [ ! -e "${loop}p1" ] && [ "$tries" -lt 50 ]; do
            sleep 0.1
            tries=$((tries + 1))
        done
        [ -e "${loop}p1" ] || exit 2
        step="formatting"
        timeout -k 5 10 mkfs.vfat -n PITHEAD "${loop}p1" >/dev/null || exit 2
        step="mount directory"
        mnt=$(mktemp -d) || exit 2
        step="mount"
        timeout -k 5 10 mount "${loop}p1" "$mnt" || exit 2
        step="configuration write"
        printf '%s' "$json" >"$mnt/pithead-config.json" || exit 2
        step="cleanup"
    )
}

_attach_media_stick() {
    cat >"$DISK.stick.xml" <<EOF
<disk type='file' device='disk'>
  <driver name='qemu' type='raw'/>
  <source file='$1'/>
  <target dev='sdz' bus='usb' removable='on'/>
</disk>
EOF
    virsh attach-device "$VM" "$DISK.stick.xml" --config --live >/dev/null 2>&1
}
_detach_media_stick() {
    virsh detach-device "$VM" "$DISK.stick.xml" --config --live >/dev/null 2>&1
}

# Does $1 (a raw disk with one FAT partition) still carry pithead-config.json at its root? Used after a boot
# to prove the applied stick was consumed. Host-side, so the disk must already be detached from the guest.
_media_stick_has_config() {
    local path="$1" loop mnt tries=0 rc=1
    loop=$(losetup -Pf --show "$path")
    while [ ! -e "${loop}p1" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    mnt=$(mktemp -d)
    mount -o ro "${loop}p1" "$mnt" 2>/dev/null && {
        [ -f "$mnt/pithead-config.json" ] && rc=0
        umount "$mnt"
    }
    rmdir "$mnt"
    losetup -d "$loop"
    return $rc
}

phase_media() {
    info "phase: media (physical-presence config channel — removable stick applied at boot)"
    # ponytail: provisions via the ESP pre-seed path (already proven by the install phase's
    # second leg) rather than re-driving the wizard's HTTP flow — this phase is about the SECOND
    # stick, read by a running appliance, not first-boot setup.
    local img loop mnt tries=0
    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return
    }
    loop=$(losetup -Pf --show "$img")
    while [ ! -e "${loop}p1" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    mnt=$(mktemp -d)
    mount "${loop}p1" "$mnt"
    printf '{"monero":{"wallet_address":"%s"},"tari":{"wallet_address":"%s"},"p2pool":{"pool":"mini","stratum_password":"auto"}}' \
        "$HARNESS_WALLET" "$HARNESS_TARI" >"$mnt/pithead-config.json"
    umount "$mnt"
    rmdir "$mnt"
    losetup -d "$loop"

    _vm_boot_disk "$img" && _wait_ssh 300 || {
        bad "guest never answered SSH (ip: ${ip:-none})"
        return
    }
    if ! _ssh "for i in \$(seq 90); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        bad "the ESP pre-seed never reached the running system — nothing to change from here"
        return
    fi
    local deadline=$(($(date +%s) + 1500)) names=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*) ok "provisioned via ESP pre-seed, stack up ($ip)" ;;
    *)
        bad "stack never came up within 25m — running: '${names:-none}'"
        stack_never_up_evidence # #2043: the guest is recycled next, so ask it now
        return
        ;;
    esac
    # A listed stack is not a finished provisioning: `up` may still wait on tor's healthcheck and hold the mutation lock (#1945, #2648, #2661).
    if provisioning_settled 900 && ! provisioning_setup_failed; then
        ok "provisioning finished before the day-two legs ($(provisioning_state))"
    else
        bad "provisioning never finished, or its setup failed; the day-two legs cannot run ($(provisioning_state))"
        return
    fi

    # ---- apply leg: a real change, shown, counted down, applied, consumed --------------------
    # A MINIMAL stick on purpose — wallet + pool, nothing else. Settings it does not name must
    # keep their running values: the full-replace bug unset the generated dashboard password
    # (serving the dashboard to the LAN with no login), dropped the appliance defaults, and
    # regenerated the node credentials on every apply. Capture the pre-apply values now so the
    # post-apply asserts compare against what the machine actually had.
    local old_pw old_user old_npw
    old_pw=$(_ssh "jq -r '.dashboard.auth.password // \"\"' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    old_user=$(_ssh "jq -r '.dashboard.auth.username // \"admin\"' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    old_npw=$(_ssh "jq -r '.monero.node_password // \"\"' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ -n "$old_pw" ] && ok "a generated dashboard password exists before the media apply" ||
        bad "no generated dashboard password before the media apply — nothing to preserve"

    local stick1="${DISK%.img}-media-apply.img"
    local new_wallet="44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
    _make_media_stick "$stick1" \
        "{\"monero\":{\"wallet_address\":\"$new_wallet\"},\"p2pool\":{\"pool\":\"nano\"}}" || {
        bad "media apply fixture construction failed before guest attachment"
        return
    }
    ok "media apply fixture constructed and released before guest attachment"
    _attach_media_stick "$stick1" || {
        bad "media apply fixture attachment failed"
        return
    }
    : >"$SERIAL"
    _ssh reboot >/dev/null 2>&1 || true

    wait_serial "staged configuration differs from the running one" 180 &&
        ok "the exact diff is shown on the console before anything applies" ||
        bad "no diff banner appeared on the console"
    if serial_has "$new_wallet"; then
        ok "the changed wallet address is shown in full — verifying it is the point"
    else
        bad "the changed wallet address never appeared on the console"
    fi
    wait_serial "Media configuration channel: applied" 120 &&
        ok "the countdown ran out and the change applied" ||
        bad "no applied confirmation ever appeared on the console"
    _wait_ssh 180 || {
        bad "guest never came back after the applied change"
        return
    }
    local pool_now
    pool_now=$(_ssh "jq -r '.p2pool.pool' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ "$pool_now" = "nano" ] && ok "the changed setting took effect (p2pool.pool: mini -> nano)" ||
        bad "the changed setting did not take effect (p2pool.pool is '${pool_now:-unknown}')"

    # ---- preservation asserts: everything the minimal stick did not name is still there ------
    local pw_now ctl_now heal_now npw_now
    pw_now=$(_ssh "jq -r '.dashboard.auth.password // \"\"' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    if [ -n "$old_pw" ] && [ "$pw_now" = "$old_pw" ]; then
        ok "the dashboard password the stick never named is unchanged — the old login still holds"
    else
        bad "the dashboard password was dropped or regenerated by a stick that never named it"
    fi
    ctl_now=$(_ssh "jq -r '.dashboard.control.enabled' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    heal_now=$(_ssh "jq -r '.tor.auto_heal' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ "$ctl_now" = "true" ] && [ "$heal_now" = "true" ] &&
        ok "the appliance defaults survive a minimal stick (control channel on, tor auto-heal on)" ||
        bad "appliance defaults dropped (control.enabled=$ctl_now tor.auto_heal=$heal_now)"
    npw_now=$(_ssh "jq -r '.monero.node_password // \"\"' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ -n "$npw_now" ] && [ "$npw_now" = "$old_npw" ] &&
        ok "the node credentials do not churn on a media apply" ||
        bad "monero node credentials were regenerated by a stick that never named them"

    # The end-to-end proof the issue asks for: after the minimal-stick apply, the served dashboard still
    # DEMANDS a login, and the pre-apply credentials still open it. Poll until caddy answers — the pool change
    # restarts the stack, so the front door lags the reboot. One readiness deadline covers BOTH probes: a
    # post-apply boot re-loads every baked image before compose up, and under bench load that runs past 10
    # minutes with caddy up (401) while the dashboard behind it still answers 502. The bench proved every
    # intermediate (000/000, 401/502, late-2xx) is the same slow settle — so poll each probe to its OWN
    # success within a shared 900 s window instead of judging a settling stack once.
    local http_deadline=$(($(date +%s) + 900)) code=000 authed=000
    while [ "$(date +%s)" -lt "$http_deadline" ]; do
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
        case "$code" in 000 | 5??) sleep 10 ;; *) break ;; esac
    done
    if [ "$code" = "401" ]; then
        ok "the dashboard still demands a login after the minimal-stick apply (HTTP 401)"
    else
        bad "the dashboard answered HTTP $code without credentials after the minimal-stick apply"
    fi
    while [ "$(date +%s)" -lt "$http_deadline" ]; do
        authed=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 -u "$old_user:$old_pw" "https://$ip/" 2>/dev/null || true)
        case "$authed" in 000 | 5??) sleep 10 ;; *) break ;; esac
    done
    case "$authed" in
    2?? | 3??) ok "the pre-apply dashboard login still works (HTTP $authed)" ;;
    *) bad "the pre-apply dashboard login no longer works (HTTP $authed)" ;;
    esac

    _detach_media_stick
    sleep 2
    if _media_stick_has_config "$stick1"; then
        bad "the applied stick still carries pithead-config.json — it would re-apply next boot"
    else
        ok "the applied stick is consumed — it cannot re-apply on a later boot"
    fi
    rm -f "$stick1"

    local stick2="${DISK%.img}-media-abort.img"
    _make_media_stick "$stick2" \
        "{\"monero\":{\"wallet_address\":\"$HARNESS_WALLET\"},\"tari\":{\"wallet_address\":\"$HARNESS_TARI\"},\"p2pool\":{\"pool\":\"mini\",\"stratum_password\":\"auto\"}}" || {
        bad "media abort fixture construction failed before guest attachment"
        return
    }
    ok "media abort fixture constructed and released before guest attachment"
    _attach_media_stick "$stick2" || {
        bad "media abort fixture attachment failed"
        return
    }
    : >"$SERIAL"
    _ssh reboot >/dev/null 2>&1 || true
    wait_serial "staged configuration differs from the running one" 180 || bad "no diff banner on the abort leg"
    _detach_media_stick || info "detach-device returned rc $? — the guest may still see the stick"
    wait_serial "Media configuration channel: cancelled" 90 &&
        ok "removing the media mid-countdown cancels the change, and says so on the console" || {
        [ -f "$SERIAL.failed" ] || [ ! -s "$SERIAL" ] || cp "$SERIAL" "$SERIAL.failed" 2>/dev/null
        local kept="console kept at $SERIAL.failed"
        [ -s "$SERIAL.failed" ] || kept="the guest produced no console output, so none was kept"
        bad "no cancellation confirmation on the console within 90 s of the pull — the channel's last line: '$(tr -d '\r' 2>/dev/null <"$SERIAL" | grep -o 'Media configuration channel: .*' | tail -1)'; $kept"
    }
    _wait_ssh 180 || {
        bad "guest never came back after the cancelled change"
        return
    }
    pool_now=$(_ssh "jq -r '.p2pool.pool' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ "$pool_now" = "nano" ] && ok "a cancelled change never took effect (p2pool.pool stayed nano)" ||
        bad "a cancelled change altered the running config anyway (p2pool.pool is '${pool_now:-unknown}')"
    rm -f "$stick2"
}
