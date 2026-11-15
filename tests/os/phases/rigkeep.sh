# shellcheck shell=bash
# shellcheck disable=SC2154
: "${OS_RUN_SUITE:?source via the suite runner}"
_rigkeep_verdict() { # <before-json> <after-json>
    local before="$1" after="$2"
    jq -ne --argjson b "$before" --argjson a "$after" '
        ($a.role == "rig") and
        ($b.role == "rig") and
        ($a.containers == "0") and
        ($a.containers == $b.containers) and
        (($a.worker | type) == "string") and
        ($a.worker == $b.worker) and
        (($a.pool | type) == "string") and
        ($a.pool == $b.pool) and
        ($a.access_token | test("^[0-9a-f]{32}$")) and
        ($a.miner_token == $a.access_token) and
        (if ($b.access_token | test("^[0-9a-f]{32}$")) then $a.access_token == $b.access_token else true end)
    ' >/dev/null 2>&1
}
_rigkeep_snapshot() {
    _ssh 'set -e
        rig=$(cat /data/pithead/rig.json)
        jq -nc --arg role "$(cat /data/pithead/machine-role)" \
            --arg tok "$(jq -r ".ACCESS_TOKEN // \"\"" /data/rigforge/config.json)" \
            --arg marker "$(cat /etc/pithead-test-marker 2>/dev/null)" \
            --arg containers "$(podman ps -aq | wc -l | tr -d " ")" \
            --argjson rig "$rig" \
            "{role:\$role,worker:\$rig.worker,pool:\$rig.pool,access_token:(\$rig.access_token // \"\"),miner_token:\$tok,marker:\$marker,containers:\$containers}"' 2>/dev/null
}
_rigkeep_commit_wait() { # <tries> — 0 once the new slot self-committed (A_OK=1 A_TRY=0)
    local n=0 genv=""
    while [ "$n" -lt "$1" ]; do
        genv=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
        case "$genv" in *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*) return 0 ;; esac
        sleep 10
        n=$((n + 1))
    done
    printf '%s' "${genv:-unreadable}"
    return 1
}
_rigkeep_adopt() {
    local coord_vm="${VM}-coord" coord_disk="${DISK%.img}-coord.img" coord_serial="${SERIAL%.log}-coord.log"
    local rig_vm="$VM" rig_disk="$DISK" rig_serial="$SERIAL" rig_ip="$ip"
    local coord_ok=0 jar="" token="" new_card=""
    kvm_preflight || return 1
    VM="$coord_vm" DISK="$coord_disk" SERIAL="$coord_serial" ip=""
    if _provision_remote_node_coordinator "$img" "$mh" "$rpc" "$zmq" "$mu" "$mp" "$th" "$grpc"; then
        coord_ok=1
        coord_ip="$ip"
        coord_user="$dash_user"
        coord_pass="$dash_pass"
    fi
    VM="$rig_vm" DISK="$rig_disk" SERIAL="$rig_serial" ip="$rig_ip"
    [ "$coord_ok" = 1 ] || {
        bad "M13: the coordinator guest never released — cannot adopt the installed rig (#3995)"
        return 1
    }
    ok "M13: the coordinator answers at $coord_ip for the installed rig (#3995)"
    _setup_again_boot 300 || {
        bad "M13: the installed rig never opened the set-up-again page (#3995)"
        return 1
    }
    _setup_again_session || {
        rm -f "$jar"
        bad "M13: no wizard session on the installed rig's set-up-again boot (#3995)"
        return 1
    }
    new_card=$(_setup_again_rig_submit kvm-rig-share "$coord_ip:3333" .)
    rm -f "$jar"
    [ -n "$new_card" ] || {
        bad "M13: re-pointing the installed rig at the coordinator failed (#3995)"
        return 1
    }
    printf '%s' "$new_card" | jq -e '.token | type == "string" and length > 0' >/dev/null || {
        bad "M13: no card token came back from the re-pointed rig (#3995)"
        return 1
    }
    rig_card="$new_card"
    _rig_mining_up 36 || {
        bad "M13: the installed rig never resumed mining at the coordinator (#3995)"
        return 1
    }
    ok "M13: the installed rig mines at the coordinator (#3995)"
    rig_adopt_leg || {
        bad "M13: dashboard adoption did not complete before the reinstall (#3995)"
        return 1
    }
    adopted=1
}
_rigkeep_teardown() {
    _rig_share_coord_teardown "${VM}-coord" "${DISK%.img}-coord.img" "${SERIAL%.log}-coord.log"
    rm -f /srv/code/bench-vm/pithead-target.img
}
_rigkeep_run() {
    local img target_disk="/srv/code/bench-vm/pithead-target.img"
    local mh="${PITHEAD_OS_MONERO_NODE_HOST:-}" rpc="${PITHEAD_OS_MONERO_RPC_PORT:-}" zmq="${PITHEAD_OS_MONERO_ZMQ_PORT:-}"
    local mu="${PITHEAD_OS_MONERO_NODE_USERNAME:-}" mp="${PITHEAD_OS_MONERO_NODE_PASSWORD:-}"
    local th="${PITHEAD_OS_TARI_NODE_HOST:-}" grpc="${PITHEAD_OS_TARI_GRPC_PORT:-}"
    # shellcheck disable=SC2034  # coord_user, coord_pass and rig_card are read through dynamic scope
    local coord_ip="" coord_user="" coord_pass="" rig_card="" adopted=0
    local before="" after="" marker="" genv="" img2="" token="" tries=0 jar="" scode="" hcode="" label=""

    _phase_install_rig || return 1

    if [ -z "$mh" ] || [ -z "$rpc" ] || [ -z "$zmq" ]; then
        it_skip_leg "M13 adoption before and after the Keep-everything reinstall (#3995)" \
            "no reserved remote Monero node for this bench — set PITHEAD_OS_MONERO_NODE_HOST, PITHEAD_OS_MONERO_RPC_PORT and PITHEAD_OS_MONERO_ZMQ_PORT to run it" missing
    else
        _rigkeep_adopt || return 1
    fi

    before=$(_rigkeep_snapshot)
    printf '%s' "$before" | jq -e '(.worker | type) == "string" and (.pool | type) == "string" and .role == "rig"' >/dev/null || {
        bad "M13: the rig's identity before the reinstall is unreadable (#3995)"
        return 1
    }
    ok "M13: identity snapshot recorded before the reinstall (#3995)"

    img2=$(_build_image v2 v2) || {
        bad "M13: building the newer image (marker v2, build label v2) failed (/tmp/os-fault-build.log)"
        return 1
    }
    _ssh "systemctl poweroff" 2>/dev/null || true
    sleep 8
    vm_destroy_or_refuse || return 1
    cp "$img2" "$DISK" || {
        bad "M13: staging the newer image on the removable stick failed (#3995)"
        return 1
    }
    qemu-img resize "$DISK" 16G >/dev/null 2>&1 || true
    (umask 077 && : >"$SERIAL") && chmod 600 "$SERIAL" || {
        bad "M13: could not protect the installer console capture (#3995)"
        return 1
    }
    kvm_preflight || return 1
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "M13: could not boot the newer image beside the installed disk (#3995)"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 240 || {
        bad "M13: the newer image never answered SSH beside the installed disk (#3995)"
        return 1
    }
    marker=$(_marker)
    [ "$marker" = "v2" ] || {
        bad "M13: the booted stick carries marker '${marker:-none}', not the v2 image this phase built (#3995)"
        return 1
    }
    ok "M13: the newer image on the stick is the built v2 image (#3995)"
    if _ssh "pithead-install --list" | grep -q "pithead-with-data"; then
        ok "M13: the newer installer reads the rig's disk as carrying data (#3995)"
    else
        bad "M13: the newer installer does not flag the rig's disk as pithead-with-data (#3995)"
    fi
    while [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] && break
        sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "M13: no installer token on the newer image's console (#3995)"
        return 1
    }
    _wait_setup_page 180 || {
        bad "M13: the newer image's setup page never served (#3995)"
        return 1
    }
    jar=$(mktemp)
    printf '%s' "$token" | curl -fsSk -m 20 -c "$jar" --data-urlencode token@- "https://$ip/auth" -o /dev/null 2>/dev/null || {
        rm -f "$jar"
        bad "M13: the newer installer refused its token (#3995)"
        return 1
    }
    grep -q wizard_session "$jar" || {
        rm -f "$jar"
        bad "M13: no wizard session on the newer installer (#3995)"
        return 1
    }
    scode=$(curl -sSk -b "$jar" --data "disk=vda&confirm=vda&wipe=keep" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        rm -f "$jar"
        bad "M13: the Keep-everything submit returned ${scode:-none}, want 200 (#3995)"
        return 1
    }
    ok "M13: Keep everything accepted on the newer installer (#3995)"
    sleep 3
    hcode=$(curl -sSk -b "$jar" -o /dev/null -w '%{http_code}' -m 5 "https://$ip/api/handoff" 2>/dev/null)
    rm -f "$jar"
    if [ "$hcode" = "404" ]; then
        ok "M13: Keep everything shows no credentials card — nothing is re-minted (#3995)"
    else
        bad "M13: no authenticated 404 on the Keep-everything handoff probe (HTTP ${hcode:-none}) (#3995)"
    fi
    tries=0
    while [ "$tries" -lt 90 ]; do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] && break
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 90 ] || {
        bad "M13: the Keep-everything install never powered off (#3995)"
        return 1
    }
    ok "M13: the Keep-everything install finished and switched itself off (#3995)"

    vm_destroy_or_refuse || return 1
    (umask 077 && : >"$SERIAL") && chmod 600 "$SERIAL" || {
        bad "M13: could not protect the console capture for the reinstalled boot (#3995)"
        return 1
    }
    kvm_preflight || return 1
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$target_disk,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "M13: could not boot the reinstalled rig (#3995)"
        return 1
    }
    _wait_dhcp_ip 120
    _wait_ssh 300 || {
        bad "M13: the reinstalled rig never answered SSH (#3995)"
        return 1
    }
    marker=$(_marker)
    label=$(_ssh "cat /opt/pithead/BUILD_LABEL 2>/dev/null" | tr -d '\r\n')
    if [ "$label" = "v2" ] && [ -z "$marker" ]; then
        ok "M13: the reinstalled rig boots the newer stick's system — build label v2, harness marker stripped (#3995)"
    else
        bad "M13: reinstalled disk is not the newer stick's system — build label '${label:-none}' want v2, marker '${marker:-none}' want stripped (#3995)"
    fi
    _rig_mining_up 36 &&
        ok "M13: the reinstalled rig mines on the new image (#3995)" ||
        bad "M13: the reinstalled rig is not mining on the new image (#3995)"
    after=$(_rigkeep_snapshot)
    if _rigkeep_verdict "$before" "$after"; then
        ok "M13: role, worker, pool and access token survived Keep everything unchanged (#3995)"
    else
        bad "M13: identity drifted across Keep everything (was $(printf '%s' "$before" | jq -c 'del(.access_token, .miner_token)' 2>/dev/null), now $(printf '%s' "$after" | jq -c 'del(.access_token, .miner_token)' 2>/dev/null)) (#3995)"
    fi
    genv=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
    case "$genv" in *A_OK=1*) ok "M13: the reinstall seeded its slot good before the gate ran (#3995)" ;;
    *) bad "M13: the reinstalled disk did not seed A_OK — grubenv: ${genv:-unreadable} (#3995)" ;; esac
    _reboot_wait reboot 300 || {
        bad "M13: the reinstalled rig never returned from the commit reboot (#3995)"
        return 1
    }
    _rig_mining_up 24 &&
        ok "M13: the reinstalled rig returns mining unaided after the commit reboot (#3995)" ||
        bad "M13: the reinstalled rig stopped mining across the commit reboot (#3995)"
    genv=$(_rigkeep_commit_wait 18) &&
        ok "M13: the new image self-committed on the mining rig (A_OK=1 A_TRY=0) (#3995)" ||
        bad "M13: the new image never self-committed — grubenv: ${genv:-unreadable} (#3995)"
    if [ "$adopted" = 1 ]; then
        if _rig_adopt_state true; then
            ok "M13: the coordinator still reads the rig as the same adopted worker after Keep everything — nothing to redo (#3995)"
        else
            bad "M13: the coordinator no longer reads the rig as the same adopted worker after Keep everything (#3995)"
        fi
    fi
    return 0
}
phase_rigkeep() {
    info "phase: rigkeep (M13 #3995 — a newer image over an installed rig's /data: Keep everything)"
    local rc=0
    _rigkeep_run || rc=$?
    _rigkeep_teardown
    return "$rc"
}
