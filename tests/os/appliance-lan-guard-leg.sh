#!/usr/bin/env bash
# LAN-only sources on the appliance's published node ports (#2616). Sourced by tests/os/run.sh.
#
# The `inet pithead_lan` nftables table (lib/pithead/02a-lan-guard.sh) is the appliance's backend;
# the e2e channel runs Docker and proves the iptables one, so this leg is the nft backend's only
# live coverage. It turns the three *_lan_access switches on with a host-side apply (the dashboard
# refuses those keys by design), then dials every published port from two throwaway network
# namespaces in the guest, each on a veth to the host: from 198.51.100.2 (TEST-NET-2, not private)
# the dial must fail, from 10.254.254.2 it must connect. The private dial is the control that the
# port is really published and listening. The config snapshot is restored whatever the verdict.

# Prints open or closed for a dial from <a.b.c>.2 to <a.b.c>.1:<port> in the guest; prints nothing
# if the namespace could not be built.
_lan_guard_probe() { # <a.b.c> <port>
    SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "ip netns del pht-lanprobe 2>/dev/null; ip link del pht-lp0 2>/dev/null
ip netns add pht-lanprobe &&
    ip link add pht-lp0 type veth peer name pht-lp1 &&
    ip link set pht-lp1 netns pht-lanprobe &&
    ip addr add $1.1/30 dev pht-lp0 && ip link set pht-lp0 up &&
    ip netns exec pht-lanprobe sh -c 'ip addr add $1.2/30 dev pht-lp1 && ip link set pht-lp1 up && ip link set lo up' &&
    if ip netns exec pht-lanprobe timeout 5 bash -c 'exec 3<>/dev/tcp/$1.1/$2' 2>/dev/null; then echo open; else echo closed; fi
ip netns del pht-lanprobe 2>/dev/null; true" 2>/dev/null | tr -d '\r'
}

phase_provision_lan_guard() { # <phase-rc>
    local unexercised=bad port container got deadline doctor
    [ "${1:-0}" -eq 0 ] || unexercised=info
    info "phase: LAN-only sources on the published node ports, nft backend (#2616)"
    if ! SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh true 2>/dev/null; then
        "$unexercised" "guest is unreachable — the LAN-only source rule was NOT exercised (#2616)"
        return 0
    fi
    _control_requests_drained || {
        "$unexercised" "LAN guard: the control spool never drained — a host-side apply here would kill a request in flight"
        return 0
    }
    approval_capture_restore_snapshot || {
        "$unexercised" "LAN guard: could not snapshot the guest's config.json"
        return 0
    }
    if ! _ssh 'set -eu
cd /data/pithead
jq -c ".monero.rpc_lan_access = true | .monero.zmq_lan_access = true | .tari.grpc_lan_access = true" config.json >config.json.lan-test
mv config.json.lan-test config.json
./pithead apply -y' >/dev/null 2>&1; then
        bad "LAN guard: ./pithead apply -y did not accept the three LAN switches"
        approval_restore_pending || bad "LAN guard: cleanup after a failed apply also failed"
        return 0
    fi
    for port in 18081 18083 18142; do
        container=monerod
        [ "$port" = 18142 ] && container=tari
        if ! _ssh "podman ps --format '{{.Names}}' | grep -qx $container" 2>/dev/null; then
            info "LAN guard: $container is not running on this guest — port $port not exercised"
            continue
        fi
        # The node recreated by the apply needs time to listen; the private dial is what says so.
        deadline=$(($(date +%s) + 300))
        got=""
        while [ "$(date +%s)" -lt "$deadline" ]; do
            got=$(_lan_guard_probe 10.254.254 "$port")
            [ "$got" = open ] && break
            sleep 10
        done
        if [ "$got" != open ]; then
            bad "LAN guard: port $port never accepted a private source (${got:-probe failed}) — the drop below would prove nothing"
            continue
        fi
        ok "LAN guard: port $port accepts a private source (10.254.254.2)"
        got=$(_lan_guard_probe 198.51.100 "$port")
        if [ "$got" = closed ]; then
            ok "LAN guard: port $port drops a non-private source (198.51.100.2)"
        else
            bad "LAN guard: port $port answered a non-private source (${got:-probe failed}) — the nft rule is not enforced"
        fi
    done
    doctor=$(_ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor" 2>/dev/null) || true
    case "$doctor" in
    *"LAN-only sources enforced on port(s)"*) ok "LAN guard: doctor reads the live nft table back as enforced" ;;
    *) bad "LAN guard: doctor did not report the LAN-only rule as enforced" ;;
    esac
    approval_restore_pending || bad "LAN guard cleanup (restoring the original config) failed"
}
