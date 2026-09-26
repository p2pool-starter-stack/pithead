# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# LAN-only sources on the node ports the *_lan_access switches publish (#2616), proved on the wire:
# each published port is dialled from a throwaway network namespace wired to the host by a veth,
# once from a non-private source (198.51.100.0/30, TEST-NET-2) that must be dropped, and once from a
# private one (10.254.254.0/30) that must connect. The private dial is the control: without it a
# broken probe or a dead daemon would read as "refused". The target is the host end of the veth, a
# local address, so the packet takes the same DNAT -> FORWARD path as a dial from another machine.

# Prints open or closed for a dial from <a.b.c>.2 to <a.b.c>.1:<port>; prints nothing if the
# namespace could not be built.
_lan_probe() { # <a.b.c> <port>
    rx "sudo ip netns del pht-lanprobe 2>/dev/null; sudo ip link del pht-lp0 2>/dev/null
        sudo ip netns add pht-lanprobe &&
            sudo ip link add pht-lp0 type veth peer name pht-lp1 &&
            sudo ip link set pht-lp1 netns pht-lanprobe &&
            sudo ip addr add $1.1/30 dev pht-lp0 && sudo ip link set pht-lp0 up &&
            sudo ip netns exec pht-lanprobe sh -c 'ip addr add $1.2/30 dev pht-lp1 && ip link set pht-lp1 up && ip link set lo up' &&
            if sudo ip netns exec pht-lanprobe timeout 5 bash -c 'exec 3<>/dev/tcp/$1.1/$2' 2>/dev/null; then echo open; else echo closed; fi
        sudo ip netns del pht-lanprobe 2>/dev/null; true"
}

assert_lan_guard_live() { # <config>
    local config="$1" ports="" p mode tmode
    mode="$(jq_get "$config" '.monero.mode')"
    tmode="$(jq_get "$config" '.tari.mode')"
    if [ "${mode:-local}" = local ]; then
        [ "$(jq_get "$config" '.monero.rpc_lan_access')" = true ] && ports="$ports 18081"
        [ "$(jq_get "$config" '.monero.zmq_lan_access')" = true ] && ports="$ports 18083"
    fi
    [ "${tmode:-local}" = local ] && [ "$(jq_get "$config" '.tari.grpc_lan_access')" = true ] && ports="$ports 18142"
    [ -n "$ports" ] || return 0
    for p in $ports; do
        assert_eq "LAN port $p: a non-private source cannot connect (#2616)" "$(_lan_probe 198.51.100 "$p")" closed
        assert_eq "LAN port $p: a private source can (#2616)" "$(_lan_probe 10.254.254 "$p")" open
    done
    # shellcheck disable=SC2086 # one argument per port
    assert_lan_guard_boot_restore $ports
}

# DIY reboot restore (#2749), without rebooting the bench: a reboot empties PITHEAD-LAN and its
# DOCKER-USER jumps while dockerd restarts the nodes still published on 0.0.0.0, and
# pithead-lan-guard.service is what puts the rule back first. Check docker.service pulls the unit in
# and waits for it, strip the rule as a reboot does (the open dial is the control that the strip
# took), run the installed unit on the real kernel, and dial again. Docker hosts only: podman has no
# unit, its boot path is `up`.
assert_lan_guard_boot_restore() { # <port>...
    local p rc=0
    [ "$(rx 'bash -c "source ./pithead && container_engine"')" = docker ] || return 0
    assert_eq "up installed and enabled the LAN-guard boot unit (#2749)" \
        "$(rx 'systemctl is-enabled pithead-lan-guard.service 2>/dev/null')" "enabled"
    assert_contains "docker.service pulls it in (#2749)" "$(rx 'systemctl show -p Wants --value docker.service')" "pithead-lan-guard.service"
    assert_contains "docker.service starts only after it (#2749)" "$(rx 'systemctl show -p After --value docker.service')" "pithead-lan-guard.service"
    rx 'bash -c "source ./pithead && remove_lan_guard"' >/dev/null 2>&1 || true
    assert_eq "the rule is gone, as after a reboot" "$(rx 'sudo iptables-save 2>/dev/null | grep -c pithead-lan-guard')" "0"
    assert_eq "control: with the rule gone, a non-private source reaches port $1" "$(_lan_probe 198.51.100 "$1")" open
    rx 'sudo systemctl restart pithead-lan-guard.service' >/dev/null 2>&1 || rc=$?
    assert_rc "the boot unit starts cleanly on the real kernel (#2749)" "$rc" "0"
    for p in "$@"; do
        assert_eq "after the boot unit, port $p: a non-private source cannot connect (#2749)" "$(_lan_probe 198.51.100 "$p")" closed
        assert_eq "after the boot unit, port $p: a private source can (#2749)" "$(_lan_probe 10.254.254 "$p")" open
    done
    rc=0
    rx "bash -c 'source ./pithead && lan_guard_enforced $*'" >/dev/null 2>&1 || rc=$?
    assert_rc "the rule it restored reads as enforced, as apply's does (#2749)" "$rc" "0"
}
