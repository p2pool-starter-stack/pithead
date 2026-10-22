# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034

RIG_SHARE_WINDOW_SEC="${PITHEAD_OS_RIG_SHARE_WINDOW_SEC:-600}"

_rig_share_coord_teardown() {
    virsh destroy "$1" >/dev/null 2>&1 || true
    virsh undefine "$1" --nvram >/dev/null 2>&1 || true
    rm -f "$2" "$3"
}

_rig_share_abort() {
    [ -z "${1:-}" ] || bad "$1"
    _rig_share_hosts_restore || bad "share leg: could not restore the rig hosts fixture and read-only root (#3425)"
    _rig_share_coord_teardown "$coord_vm" "$coord_disk" "$coord_serial"
    return 1
}

_rig_share_hosts_restore() {
    _ssh '
        rc=0
        if [ -f /data/rig-share-hosts.original ]; then
            if mount -o remount,rw /; then
                cat /data/rig-share-hosts.original > /etc/hosts && rm -f /data/rig-share-hosts.original || rc=1
            else
                rc=1
            fi
        fi
        mount -o remount,ro / || rc=1
        findmnt -rn -o OPTIONS / | tr , "\n" | grep -Fxq ro || rc=1
        exit "$rc"'
}

_rig_share_hosts_install() {
    _ssh "
        test ! -e /data/rig-share-hosts.original || exit 1
        mount -o remount,rw / || exit 1
        rc=0
        cp -p /etc/hosts /data/rig-share-hosts.original &&
            printf '%s %s\\n' '$coord_ip' '$coord_name' >> /etc/hosts || rc=1
        mount -o remount,ro / || rc=1
        findmnt -rn -o OPTIONS / | tr , '\\n' | grep -Fxq ro || rc=1
        exit \"\$rc\""
}

_rig_share_resolves() {
    local resolved
    resolved=$(_ssh "getent ahostsv4 '$1' | awk '{print \$1}' | sort -u") || return 1
    [ "$(printf '%s' "$resolved" | tr -d '\r')" = "$2" ]
}

_rig_share_state() {
    curl -fsSk -u "$coord_user:$coord_pass" -m 10 "https://$coord_ip/api/state"
}

_rig_share_counters() {
    jq -er --arg coordinator "$coord_worker" '
        [.workers[] | select(.name == "kvm-rig-share")] as $rig |
        [.workers[] | select(.name == $coordinator)] as $coord |
        select(($rig | length) > 0 and ($coord | length) > 0) |
        select(all($coord[]; .accepted | type == "number" and . >= 0 and floor == .)) |
        select(all($rig[]; all(.accepted, .rejected, .invalid;
            type == "number" and . >= 0 and floor == .) and
            (.h60 | type == "number" and . >= 0))) |
        [($rig | map(.accepted) | add), ($rig | map(.rejected) | add),
         ($rig | map(.invalid) | add),
         ([$rig[] | select(.status == "online") | .h60] | max // 0),
         ($coord | map(.accepted) | add)] |
        @tsv'
}

_rig_share_observation() {
    jq -ec --arg coordinator "$coord_worker" '
        select(.workers | type == "array") |
        {worker_rows: (.workers | length),
         rig: [.workers[] | select(.name == "kvm-rig-share")],
         coordinator: [.workers[] | select(.name == $coordinator)]} |
        .rig_rows = (.rig | length) | .coordinator_rows = (.coordinator | length) |
        .rig |= (.[0:2] | map({accepted: (.accepted | numbers? // null),
            rejected: (.rejected | numbers? // null), invalid: (.invalid | numbers? // null),
            h60: (.h60 | numbers? // null), online: (.status == "online")})) |
        .coordinator |= (.[0:2] | map({accepted: (.accepted | numbers? // null)}))'
}

_rig_share_window() {
    local arm="$1" baseline="$2" deadline counters accepted rejected invalid rate other good_reads=0
    local st observation="state-unavailable" first=1 state_ok=0
    deadline=$(($(date +%s) + RIG_SHARE_WINDOW_SEC))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        observation="state-unavailable"
        st=""
        state_ok=0
        if st=$(_rig_share_state); then
            state_ok=1
            observation=$(printf '%s' "$st" | _rig_share_observation) || observation="state-malformed"
        fi
        if [ "$first" = 1 ]; then
            info "share leg $arm: baseline=$baseline initial=$observation (#3425)"
            first=0
        fi
        if [ "$state_ok" = 1 ] && counters=$(printf '%s' "$st" | _rig_share_counters); then
            IFS=$'\t' read -r accepted rejected invalid rate other <<<"$counters"
            if [ "$rejected" != 0 ] || [ "$invalid" != 0 ]; then
                info "share leg $arm: baseline=$baseline final=$observation (#3425)"
                bad "share leg $arm: rejected or invalid shares on the rig worker (#3425)"
                return 1
            fi
            if [ "$accepted" -gt "$baseline" ] &&
                jq -en --argjson rate "$rate" --argjson other "$other" '$rate > 0 and $other > 0' >/dev/null; then
                good_reads=$((good_reads + 1))
                if [ "$good_reads" -ge 2 ]; then
                    info "share leg $arm: baseline=$baseline final=$observation (#3425)"
                    ok "share leg $arm: fresh accepted shares, positive live hashrate, zero rejected and invalid (#3425)"
                    return 0
                fi
            else
                good_reads=0
            fi
        else
            good_reads=0
        fi
        sleep 15
    done
    info "share leg $arm: baseline=$baseline final=$observation (#3425)"
    bad "share leg $arm: no fresh accepted shares with positive live hashrate and coordinator shares within ${RIG_SHARE_WINDOW_SEC}s (#3425)"
    return 1
}

_rig_share_arm() {
    local arm="$1" pool="$2" jar="" token="" new_card="" baseline st
    _rig_share_resolves "${pool%:*}" "$coord_ip" || return 2
    _setup_again_boot 300 || return 1
    _setup_again_session || return 1
    st=$(_rig_share_state) || {
        rm -f "$jar"
        return 1
    }
    baseline=$(printf '%s' "$st" | jq -er '
        [.workers[] | select(.name == "kvm-rig-share") | .accepted] |
        select(all(.[]; type == "number" and . >= 0 and floor == .)) | add // 0') || {
        rm -f "$jar"
        bad "share leg $arm: accepted baseline unavailable (#3425)"
        return 1
    }
    new_card=$(_setup_again_rig_submit kvm-rig-share "$pool") || {
        rm -f "$jar"
        return 1
    }
    rm -f "$jar"
    [ -n "${new_card%% *}" ] || {
        bad "share leg $arm: no card token returned"
        return 1
    }
    _rig_mining_up 36 || {
        bad "share leg $arm: rig never resumed mining"
        return 1
    }
    _rig_share_resolves "${pool%:*}" "$coord_ip" || {
        bad "share leg $arm: pool resolution changed across re-provisioning (#3425)"
        return 1
    }
    _ssh "jq -e --arg pool '$pool' '.pools | length == 1 and .[0].url == \$pool' /data/rigforge/config.json >/dev/null" || {
        bad "share leg $arm: miner config does not contain exactly the requested pool (#3425)"
        return 1
    }
    ok "share leg $arm: miner config contains exactly the requested pool (#3425)"
    _rig_share_window "$arm" "$baseline"
}

rig_share_leg() {
    local img="$1" mh="$2" rpc="$3" zmq="$4" mu="$5" mp="$6" th="$7" grpc="$8" rig_ip="$9"
    local rig_vm="$VM" rig_disk="$DISK" rig_serial="$SERIAL"
    local coord_vm="${rig_vm}-coord" coord_disk="${rig_disk%.img}-coord.img" coord_serial="${rig_serial%.log}-coord.log"

    info "share leg (#2063) — the rig mines against a coordinator this battery itself boots, not its own sshd"
    kvm_preflight || return 1

    VM="$coord_vm" DISK="$coord_disk" SERIAL="$coord_serial" ip=""
    local coord_ok=0 coord_ip="" coord_user="" coord_pass="" coord_worker=""
    if _provision_remote_node_coordinator "$img" "$mh" "$rpc" "$zmq" "$mu" "$mp" "$th" "$grpc"; then
        coord_ip="$ip"
        coord_user="$dash_user"
        coord_pass="$dash_pass"
        coord_worker=$(_ssh hostname | tr -d '\r\n')
        [ -z "$coord_worker" ] || [ "$coord_worker" = kvm-rig-share ] || coord_ok=1
    fi
    VM="$rig_vm" DISK="$rig_disk" SERIAL="$rig_serial" ip="$rig_ip"
    [ "$coord_ok" = 1 ] || _rig_share_abort "share leg: the coordinator guest never released — cannot prove a share against it" || return 1
    ok "share leg: coordinator released at $coord_ip, on the same libvirt network as the rig"

    local coord_name="kvm-share-coordinator.invalid"
    local control_rc=0
    _rig_share_arm hostname kvm-share-unresolved.invalid:3333 || control_rc=$?
    if [ "$control_rc" != 2 ]; then
        _rig_share_abort "share leg: unresolved hostname negative control unexpectedly resolved" || return 1
    else
        ok "share leg: unresolved hostname fails the hostname arm (#3425)"
    fi
    _rig_share_hosts_install ||
        _rig_share_abort "share leg: could not install the coordinator hostname fixture" || return 1
    _rig_share_arm address "$coord_ip:3333" || _rig_share_abort "share leg: address arm failed (#3425)" || return 1
    _rig_share_arm hostname "$coord_name:3333" || _rig_share_abort "share leg: hostname arm failed (#3425)" || return 1
    _rig_share_arm return "$coord_ip:3333" || _rig_share_abort "share leg: return arm failed (#3425)" || return 1
    _rig_share_hosts_restore || _rig_share_abort "share leg: hosts fixture restoration failed (#3425)" || return 1
    ok "share leg: rig hosts restored and root verified read-only (#3425)"
    _rig_share_coord_teardown "$coord_vm" "$coord_disk" "$coord_serial"
}
