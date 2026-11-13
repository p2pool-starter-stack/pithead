# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034

rig_small_guest_leg() { # <img>
    local img="$1" rc=0
    local saved_vm="$VM" saved_disk="$DISK" saved_serial="$SERIAL" saved_ip="$ip"
    VM="${saved_vm}-small" DISK="${saved_disk%.img}-small.img" SERIAL="${saved_serial%.log}-small.log" ip=""
    _rig_small_guest_run "$img" || rc=1
    virsh destroy "$VM" >/dev/null 2>&1 || true
    virsh undefine "$VM" --nvram >/dev/null 2>&1 || true
    rm -f "$DISK" "$SERIAL"
    VM="$saved_vm" DISK="$saved_disk" SERIAL="$saved_serial" ip="$saved_ip"
    return "$rc"
}

_rig_small_guest_run() { # <img>
    local img="$1" token="" tries=0 jar body scode sysfile pool after mounts unitlog
    local mode rtok light hr cls ptries=0 oom
    info "small-guest leg (#4010) — the rig role on a 2 GiB, 1 vCPU machine: it must mine, not over-reserve"
    cp "$img" "$DISK" || {
        bad "could not copy the image for the 2 GiB rig guest"
        return 1
    }
    qemu-img resize "$DISK" 40G >/dev/null 2>&1 || true
    : >"$SERIAL" && chmod 600 "$SERIAL"
    PITHEAD_KVM_MIN_AVAIL_MB=6144 kvm_preflight || return 1
    local vierr
    vierr=$(virt-install --name "$VM" --memory 2048 --vcpus 1 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$DISK,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole 2>&1) || {
        bad "virt-install could not define the 2 GiB, 1 vCPU rig guest: $(printf '%s' "$vierr" | tail -3 | tr '\n' ' ' | cut -c1-300)"
        return 1
    }
    _wait_dhcp_ip 360 || {
        bad "the 2 GiB guest never took a DHCP lease (domstate: $(virsh domstate "$VM" 2>&1 | tr '\n' ' ' | cut -c1-120))"
        return 1
    }
    _wait_ssh 600 || {
        bad "the 2 GiB guest booted but its SSH never came up ($(_ssh_unreachable_reason "$ip"))"
        return 1
    }
    ok "the appliance boots on 2 GiB and 1 vCPU ($ip)"
    while [ -z "$token" ] && [ "$tries" -lt 60 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token printed on the 2 GiB guest's console"
        return 1
    }
    _wait_setup_page 240 || {
        bad "the 2 GiB guest never served the setup page"
        return 1
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null || {
        bad "the token gate refused auth on the 2 GiB guest"
        rm -f "$jar"
        return 1
    }
    body="role=rig&rig_pool=127.0.0.1:22&rig_worker=kvm-rig-small"
    scode=$(curl -sSk -b "$jar" --data "$body" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    rm -f "$jar"
    [ "$scode" = "200" ] || {
        bad "the rig submit did not return 200 on the 2 GiB guest (got ${scode:-none})"
        return 1
    }
    [ "$(_ssh 'cat /data/pithead/machine-role' | tr -d '\r\n')" = "rig" ] || {
        bad "the 2 GiB guest never became a rig"
        return 1
    }
    ok "the 2 GiB machine provisioned as a rig"

    sysfile=$(_ssh 'tr -d "[:space:]" < /etc/sysctl.d/99-pithead-hugepages.conf 2>/dev/null' | tr -d '\r\n')
    [ "$sysfile" = "vm.nr_hugepages=3072" ] &&
        ok "the image still bakes the 3072-page default — the coordinator keeps its reservation" ||
        bad "the baked sysctl is not what the rootfs declares: '${sysfile:0:60}'"
    pool=$(_ssh 'cat /proc/sys/vm/nr_hugepages 2>/dev/null' | tr -d '\r\n ')
    [ "$pool" = "0" ] &&
        ok "#4010: the baked 3072-page default did not stick — the rig reserved no hugepages" ||
        bad "#4010: the rig's pool holds ${pool:-?} pages — it over-reserved instead of leaving the sizing to RigForge"
    [ "$(_ssh 'systemctl is-active pithead-hugepages' | tr -d '\r\n')" = "active" ] &&
        ok "pithead-hugepages ran and stayed active on the rig" ||
        bad "pithead-hugepages is '$(_ssh 'systemctl is-active pithead-hugepages' 2>/dev/null | tr -d '\r\n')' on the rig"
    after=$(_ssh 'systemctl show pithead-hugepages -p After --value' | tr -d '\r\n')
    case "$after" in
    *systemd-sysctl.service*)
        ok "the unit runs after systemd-sysctl — it corrects the baked sysctl, never the reverse"
        ;;
    *) bad "the unit does not come after systemd-sysctl: After=${after:-empty}" ;;
    esac
    mounts=$(_ssh 'systemctl show pithead-hugepages -p RequiresMountsFor --value' | tr -d '\r\n')
    case "$mounts" in
    *data.mount*)
        ok "the unit waits for /data — it reads the role file rather than guessing at it"
        ;;
    *) bad "the unit does not wait for /data, so machine-role can be unreadable when it runs: RequiresMountsFor=${mounts:-empty}" ;;
    esac
    unitlog=$(_ssh "journalctl -u pithead-hugepages -b --no-pager -o cat | grep -m1 'rig role'" 2>/dev/null | tr -d '\r')
    [ -n "$unitlog" ] &&
        ok "the unit says what it did for the rig role: $(printf '%s' "$unitlog" | cut -c1-140)" ||
        bad "the unit wrote no rig-role line — the rig branch never ran"
    _ssh 'test ! -e /run/pithead-hugepages-degraded' &&
        ok "no degraded-RAM marker — a rig has no RAM floor to be under" ||
        bad "the rig carries the coordinator's degraded marker — it is not degraded, it has no floor"

    mode=$(_ssh "jq -r '.xmrig.randomx.mode // \"(not rendered)\"' /data/rigforge/config.json 2>/dev/null" | tr -d '\r')
    if _rig_mining_up 36; then
        ok "#4010: the rig MINES on 2 GiB and 1 vCPU — unit active, xmrig running, pool unanswered by design"
    else
        bad "#4010: the rig does not mine on 2 GiB (xmrig unit: $(_ssh 'systemctl is-active xmrig' 2>/dev/null | tr -d '\r\n'))"
        info "  rendered RandomX mode on this machine: ${mode:-unreadable}"
        info "  xmrig journal tail: $(_ssh 'journalctl -u xmrig -n 6 --no-pager -o cat' 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
        oom=$(_ssh "journalctl -k -b --no-pager -o cat | grep -im1 -E 'out of memory|oom-kill'" 2>/dev/null | tr -d '\r' | cut -c1-160)
        [ -n "$oom" ] && info "  kernel: $oom"
        if _ssh "jq '.randomx.mode = \"auto\"' /data/rigforge/data/worker/xmrig/build/config.json >/tmp/rig-small-auto.json && mv /tmp/rig-small-auto.json /data/rigforge/data/worker/xmrig/build/config.json && systemctl restart xmrig"; then
            if _rig_mining_up 18; then
                info "  measurement: the same miner with mode auto on this 2 GiB guest mines where the rendered mode died"
            else
                info "  measurement: mode auto on this 2 GiB guest does not mine either — the failure is below the mode"
            fi
        else
            info "  measurement: could not stage the auto probe on this guest"
        fi
        return 1
    fi
    [ "$mode" = "auto" ] &&
        ok "#4010: the rig's render asks for RandomX mode auto — the machine picks the mode it can hold" ||
        bad "#4010: the rendered RandomX mode is '${mode:-unreadable}', not auto"
    light=$(_ssh "journalctl -u xmrig -b --no-pager -o cat | grep -im1 'light mode'" 2>/dev/null | tr -d '\r')
    [ -n "$light" ] &&
        ok "the machine says it mines in light mode: $(printf '%s' "$light" | cut -c1-140)" ||
        bad "the miner is running but never said a word about light mode — the fallback is invisible"
    rtok=$(_ssh "jq -r '.ACCESS_TOKEN // \"\"' /data/rigforge/config.json" | tr -d '\r')
    hr=0
    while [ "$hr" = "0" ] && [ "$ptries" -lt 6 ]; do
        sleep 10
        hr=$(_ssh "curl -s -m 5 -H \"Authorization: Bearer $rtok\" http://127.0.0.1:8081/1/summary | jq -r '(.\"hash-rate\" | if type == \"array\" then .[-1] else . end) // 0'" 2>/dev/null | tr -d '\r')
        case "$hr" in '' | *[!0-9.]*) hr=0 ;; esac
        ptries=$((ptries + 1))
    done
    cls=$(awk -v h="$hr" 'BEGIN { if (h + 0 >= 1000000) print "MH/s-class"; else if (h + 0 >= 1000) print "kH/s-class"; else if (h + 0 > 0) print "H/s-class"; else print "zero" }')
    [ "$cls" != "zero" ] &&
        ok "hashrate class recorded for a 2 GiB, 1 vCPU rig: $cls ($hr H/s)" ||
        bad "the sister feed never reported a nonzero hashrate on the 2 GiB rig"
}
