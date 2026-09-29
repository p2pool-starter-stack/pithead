# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
phase_boot() {
    info "phase: boot"
    vm_destroy_or_refuse || return
    cp "$IMAGE" "$DISK"
    # 16 GiB guest: the appliance reserves 6 GiB of hugepages at boot (RandomX), so a smaller VM
    # leaves too little for the stack — and the plan sizes appliance RAM to the compose caps anyway.
    # Grow the scratch disk before first boot: the image ships only the ESP and slot A, and
    # systemd-repart creates slot B and /data on whatever disk it finds. A 40 GiB disk leaves
    # /data around 24 GiB, which the update phase asserts.
    qemu-img resize "$DISK" 40G >/dev/null 2>&1 || true
    : >"$SERIAL"
    # UEFI (OVMF), serial to a file we tail, import the raw appliance disk as-is.
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$DISK,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 ||
        {
            bad "virt-install failed to define the VM"
            return
        }
    # NB: do NOT assert on the kernel banner — the appliance boots with loglevel=3, which keeps
    # those lines off the console entirely, so a healthy boot looks silent. The getty banner (or
    # the wizard's own announcement) is the first thing userspace reliably puts on serial.
    if wait_serial "login:|Debian GNU/Linux|Pithead setup wizard" 240; then
        ok "image boots to userspace (login banner on the serial console)"
    else
        bad "no userspace banner on serial within 240s — boot failed; check the serial log"
        return
    fi
    # The firstboot unit prints the wizard URL + one-time token to the console (phase-3 design).
    if wait_serial "firstboot-wizard|One-time token|Setup wizard is up" 180; then
        ok "first-boot wizard window opens (token printed to console)"
    else
        bad "first-boot wizard never announced itself on the console"
    fi
    # Reachable on :80 from the host once the VM has a lease.
    local ip
    _wait_dhcp_ip 60 || {
        bad "wizard not reachable — the VM never took a DHCP lease"
        return
    }
    # The console announcement fires when the wizard CONTAINER starts (`podman run -d` returns),
    # not when the Python server inside has bound its sockets — so the gate answers a little
    # after the token prints. Measured: zero on an idle host (two clean single-phase runs
    # answered the first probe), but 2 of 3 full-battery runs on the same image flaked here —
    # the gap only opens when the host is loaded, which is exactly when batteries run. A human
    # operator never sees it because reading the token and typing the URL takes longer. Same
    # retry shape as every other wizard probe in this file.
    _wait_setup_page 120 || {
        bad "wizard never served the token gate ($ip)"
        return
    }
    ok "wizard serves the token gate ($ip)"

    # SSH is a host service that starts after the wizard's HTTP gate answers, so the first _ssh here
    # must wait it out — a single-shot probe raced ssh.service and misread a healthy boot as dead.
    # 900, not the update phase's 240: this is the run's very FIRST cold boot — 6 GiB of
    # hugepages, systemd-repart growing /data, the wizard image unpacking, host-key generation —
    # and it starts while the image build's export I/O is still settling. 420 s passed idle but
    # clipped under full-battery load (proven both ways on the bench, 2026-08-15); the budget is
    # sized for the loaded case because a deadline that only holds on an idle host is a flake.
    # NOT raised again even though 900 s has since timed out too: it was proven sufficient on the
    # bench the same day on the same class of run, and a bigger arbitrary guess repeats the mistake
    # this file's history warns about (raising the ceiling instead of finding out why it was hit).
    # What changed instead is the failure message below: it names which of three things happened.
    _wait_ssh 900 || {
        bad "host SSH never came up after the wizard gate — cannot read hugepages/machine-id ($(_ssh_unreachable_reason "$ip"))"
        return
    }

    # Exercise the installed unit under systemd. The guest has a real emulated UART; a temporary
    # runtime drop-in gives the SAME ExecCondition a type-0 fixture, then is removed before reboot.
    # Keep the dead-port state for five minutes, long enough to expose the original 10 s loop.
    local getty_type getty_state getty_restarts getty_result getty_errors
    getty_type=$(_ssh 'cat /sys/class/tty/ttyS0/type' 2>/dev/null | tr -d '\r\n')
    getty_state=$(_ssh 'systemctl show -P ActiveState serial-getty@ttyS0.service' 2>/dev/null | tr -d '\r\n')
    getty_restarts=$(_ssh 'systemctl show -P NRestarts serial-getty@ttyS0.service' 2>/dev/null | tr -d '\r\n')
    if [[ "$getty_type" =~ ^[1-9][0-9]*$ ]] && [ "$getty_state" = active ] && [ "$getty_restarts" = 0 ]; then
        ok "serial getty runs on the guest's real UART without a restart"
    else
        bad "serial getty did not start cleanly on the guest UART (type ${getty_type:-unreadable}, state ${getty_state:-unreadable}, NRestarts ${getty_restarts:-unreadable})"
    fi
    if _ssh 'mkdir -p /run/systemd/system/serial-getty@ttyS0.service.d && printf "0\n" >/run/pithead-test-serial-type && cat >/run/systemd/system/serial-getty@ttyS0.service.d/pithead-test.conf && systemctl daemon-reload && systemctl restart serial-getty@ttyS0.service' <<'GETTY_DROPIN'
[Service]
ExecCondition=
ExecCondition=/usr/local/sbin/pithead-serial-port-present /run/pithead-test-serial-type
GETTY_DROPIN
    then
        sleep 300
        getty_state=$(_ssh 'systemctl show -P ActiveState serial-getty@ttyS0.service' 2>/dev/null | tr -d '\r\n')
        getty_result=$(_ssh 'systemctl show -P Result serial-getty@ttyS0.service' 2>/dev/null | tr -d '\r\n')
        getty_restarts=$(_ssh 'systemctl show -P NRestarts serial-getty@ttyS0.service' 2>/dev/null | tr -d '\r\n')
        getty_errors=$(_ssh "journalctl -b -u serial-getty@ttyS0.service -g 'failed to get terminal attributes' -q --no-pager | wc -l" 2>/dev/null | tr -d '\r\n ')
        if [ "$getty_state" = inactive ] && [ "$getty_result" = exec-condition ] && [ "$getty_restarts" = 0 ] && [ "$getty_errors" = 0 ]; then
            ok "serial getty skips a type-0 port without restarts or terminal errors for five minutes"
        else
            bad "serial getty did not stay skipped on a type-0 port (state ${getty_state:-unreadable}, result ${getty_result:-unreadable}, NRestarts ${getty_restarts:-unreadable}, terminal errors ${getty_errors:-unreadable})"
        fi
    else
        bad "could not stage a type-0 port for the serial getty's systemd condition"
    fi
    if _ssh 'rm -f /run/systemd/system/serial-getty@ttyS0.service.d/pithead-test.conf /run/pithead-test-serial-type && systemctl daemon-reload && systemctl start serial-getty@ttyS0.service'; then
        getty_state=$(_ssh 'systemctl show -P ActiveState serial-getty@ttyS0.service' 2>/dev/null | tr -d '\r\n')
        [ "$getty_state" = active ] && ok "serial getty resumes on the real UART after the type-0 check" ||
            bad "serial getty did not resume after removing the type-0 fixture (state ${getty_state:-unreadable})"
    else
        bad "could not restore the guest's serial getty after the type-0 check"
    fi
    # systemctl kill can refuse a unit with no main process during the start transition. Read a
    # concrete PID first so this row names that state and signals the process actually under test.
    local getty_deadline getty_pid="" getty_restarts_before=""
    getty_deadline=$(($(date +%s) + 20))
    while [ "$(date +%s)" -lt "$getty_deadline" ]; do
        getty_pid=$(_ssh 'systemctl show -P MainPID serial-getty@ttyS0.service' 2>/dev/null | tr -d '\r\n')
        [[ "$getty_pid" =~ ^[1-9][0-9]*$ ]] && break
        sleep 1
    done
    getty_restarts_before=$(_ssh 'systemctl show -P NRestarts serial-getty@ttyS0.service' 2>/dev/null | tr -d '\r\n')
    if [[ "$getty_pid" =~ ^[1-9][0-9]*$ && "$getty_restarts_before" =~ ^[0-9]+$ ]] && _ssh "kill -HUP $getty_pid"; then
        getty_deadline=$(($(date +%s) + 20))
        while [ "$(date +%s)" -lt "$getty_deadline" ]; do
            getty_state=$(_ssh 'systemctl show -P ActiveState serial-getty@ttyS0.service' 2>/dev/null | tr -d '\r\n')
            getty_restarts=$(_ssh 'systemctl show -P NRestarts serial-getty@ttyS0.service' 2>/dev/null | tr -d '\r\n')
            [ "$getty_state" = active ] && [[ "$getty_restarts" =~ ^[0-9]+$ ]] &&
                [ "$getty_restarts" -eq "$((getty_restarts_before + 1))" ] && break
            sleep 1
        done
        [ "$getty_state" = active ] && [[ "$getty_restarts" =~ ^[0-9]+$ ]] &&
            [ "$getty_restarts" -eq "$((getty_restarts_before + 1))" ] &&
            ok "a clean hangup respawns the serial login prompt" ||
            bad "the serial login did not respawn after a clean hangup (state ${getty_state:-unreadable}, NRestarts ${getty_restarts:-unreadable}, before ${getty_restarts_before:-unreadable})"
    else
        bad "could not send a clean hangup to the serial getty (MainPID ${getty_pid:-unreadable}, state ${getty_state:-unreadable})"
    fi

    # Hugepages are load-bearing (the RandomX dataset must land in hugetlbfs, not the cgroup —
    # the Dockerfile's own words): the baked sysctl reserves 3072 2M pages, and a boot that
    # silently lost them starves the miner while everything else looks healthy. Since #977 this
    # also aims to pin the boot-time sizing unit's no-op branch — but HugePages_Total alone reads
    # identically whether the unit ran and correctly changed nothing, or never ran at all: the
    # baked sysctl reserves the same pool either way. Pairing the page count with the unit's own
    # record (systemd's is-active, true only once the RemainAfterExit=yes oneshot has actually
    # run) tells the two apart (#1212); hugepages_boot_verdict is fixture-tested at tier 1
    # (tests/stack/run.sh) so the discrimination itself is provable without a KVM boot. The
    # degrade tiers this unit computes are proven separately, also tier-1.
    local hp active verdict
    hp=$(_ssh "awk '/^HugePages_Total/{print \$2}' /proc/meminfo" 2>/dev/null) || hp=""
    active=$(_ssh "systemctl is-active pithead-hugepages.service" 2>/dev/null | tr -d '\r\n') || active=""
    if verdict=$(hugepages_boot_verdict "$hp" "$active"); then
        ok "$verdict"
    else
        bad "$verdict"
    fi

    # #895: machine-id must be assigned once and then STAY. #1659 and #1791 ride the same reboot:
    # journald keeping the transient id (a new journal dir per boot), and the /var overlay racing the
    # #1030 bind for /var/log/journal (a split boot list). Both verdicts are fixture-tested (tier 1).
    local id_before id_after jd_before jd_after jb
    id_before=$(_ssh cat /etc/machine-id)
    jd_before=$(_ssh 'ls /var/log/journal | wc -l' | tr -d '\r\n ')
    if [ -n "$id_before" ]; then
        if _reboot_wait reboot 240; then
            id_after=$(_ssh cat /etc/machine-id)
            [ -n "$id_after" ] && [ "$id_before" = "$id_after" ] && ok "machine-id stable across a reboot ($id_before)" ||
                bad "machine-id changed across a reboot (before: $id_before, after: ${id_after:-none})"
            jd_after=$(_ssh 'ls /var/log/journal | wc -l' | tr -d '\r\n ')
            jb=$(_ssh 'journalctl -b -q --no-pager -u pithead-machine-id 2>/dev/null | wc -l' | tr -d '\r\n ')
            printf '     · journal dirs %s -> %s; journalctl -b: %s kernel lines, %s from pithead-machine-id\n' "$jd_before" "$jd_after" "$(_ssh 'journalctl -b -k -q --no-pager 2>/dev/null | wc -l' | tr -d '\r\n ')" "$jb"
            verdict=$(journal_boot_verdict "$jd_before" "$jd_after" "$jb") && ok "$verdict" || bad "$verdict"
            verdict=$(journal_home_verdict "$(_ssh "$JOURNAL_HOME_PROBE" 2>/dev/null | tr -d '\r')") && ok "$verdict" || bad "$verdict"
        else
            bad "guest never returned after the machine-id reboot check"
        fi
    else
        bad "could not read machine-id before the reboot check (test SSH unreachable)"
    fi

    _secure_boot_guest_leg
}

# A second guest, Secure Boot ON (#2055 G2). Every other virt-install in the battery pins
# firmware.feature0.enabled=no; this is the one measurement of the signed-boot chain the KVM
# battery can give without hardware — the honest alternative to leaving the flag unmeasured with
# nothing written down. Reuses $VM/$DISK/$SERIAL sequentially, same as every other guest in this
# file; the guest above is already done with them.
_secure_boot_guest_leg() {
    vm_destroy_or_refuse || return
    cp "$IMAGE" "$DISK"
    qemu-img resize "$DISK" 40G >/dev/null 2>&1 || true
    : >"$SERIAL"
    kvm_preflight || exit 1
    local defined=0 booted=0 verdict
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes \
        --import --disk "path=$DISK,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 && defined=1
    if [ "$defined" = 1 ] && wait_serial "login:|Debian GNU/Linux|Pithead setup wizard" 180; then
        booted=1
    fi
    if verdict=$(secure_boot_boot_verdict "$defined" "$booted" "$(tr -d ' \t\r\n' <VERSION)"); then
        ok "$verdict"
    else
        bad "$verdict"
    fi
}

# Boot a raw appliance disk under OVMF and return once it has a lease. Sets the global `ip`.
_vm_boot_disk() {
    vm_destroy_or_refuse || return
    cp "$1" "$DISK"
    qemu-img resize "$DISK" 40G >/dev/null 2>&1 || true
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$DISK,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || return 1
    _wait_dhcp_ip 120
}
