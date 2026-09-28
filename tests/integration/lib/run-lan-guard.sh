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
    # shellcheck disable=SC2086
    assert_lan_guard_boot_failure $ports
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

# Fail closed when the guard itself fails at boot (#2749). Stop the nodes and strip the rule as a
# reboot does, then make the guard's firewall step fail (a runtime drop-in whose iptables call
# appends to a chain that does not exist). Rebooting the shared bench is not an option, so dockerd's
# boot-time restore is applied by hand: it starts every container whose restart policy is not "no"
# (after a power loss even an unless-stopped one it did not see stopped). Before #2749 that started
# the node on 0.0.0.0 with no rule; now the node is held, doctor names it, and `./pithead up`, the
# documented recovery, brings it back behind the rule.
assert_lan_guard_boot_failure() { # <port>...
    local p c containers="" rc=0
    [ "$(rx 'bash -c "source ./pithead && container_engine"')" = docker ] || return 0
    for p in "$@"; do
        c=$(rx "bash -c 'source ./pithead && lan_guard_container $p'")
        [[ " $containers " == *" $c "* ]] || containers="$containers $c"
    done
    assert_eq "the hold unit is enabled for the next boot (#2749)" \
        "$(rx 'systemctl is-enabled pithead-lan-hold.service 2>/dev/null')" "enabled"
    assert_contains "it requires the guard (#2749)" "$(rx 'systemctl show -p Requires --value pithead-lan-hold.service')" "pithead-lan-guard.service"
    assert_eq "docker.service requires neither unit, so other containers start regardless (#2749)" \
        "$(rx 'systemctl show -p Requires --value docker.service | grep -c pithead-lan')" "0"
    for c in $containers; do
        assert_eq "$c runs with restart policy no, so dockerd never starts it at boot (#2749)" \
            "$(rx "docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $c")" "no"
    done
    # shellcheck disable=SC2086 # one argument per container
    rx "docker stop -t 30 $containers" >/dev/null 2>&1 || true
    rx 'bash -c "source ./pithead && remove_lan_guard"' >/dev/null 2>&1 || true
    rx 'sudo mkdir -p /run/systemd/system/pithead-lan-guard.service.d &&
        printf "[Service]\nExecStart=\nExecStart=/usr/sbin/iptables -A PITHEAD-LAN-FAULT-2749 -j DROP\n" |
            sudo tee /run/systemd/system/pithead-lan-guard.service.d/fault-2749.conf >/dev/null &&
        sudo systemctl daemon-reload' >/dev/null 2>&1 || true
    rx 'sudo systemctl restart pithead-lan-guard.service' >/dev/null 2>&1 || rc=$?
    assert_ne "the guard's firewall step fails (#2749)" "$rc" "0"
    rc=0
    rx 'sudo systemctl restart pithead-lan-hold.service' >/dev/null 2>&1 || rc=$?
    assert_ne "systemd refuses the hold while the guard is failed (#2749)" "$rc" "0"
    # dockerd's boot restore, by the container's real policy.
    for c in $containers; do
        rx "case \$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $c) in no) ;; *) docker start $c ;; esac" >/dev/null 2>&1 || true
    done
    for p in "$@"; do
        assert_eq "guard failed at boot, port $p: a non-private source cannot connect (#2749)" "$(_lan_probe 198.51.100 "$p")" closed
    done
    for c in $containers; do
        assert_eq "$c stays stopped while the guard is failed (#2749)" "$(rx "docker inspect -f '{{.State.Running}}' $c")" "false"
    done
    assert_contains "doctor names the held node and the recovery (#2749)" \
        "$(rx "bash -c 'source ./pithead && check_lan_guard_hold $*'" 2>&1)" "held since boot"
    # Starts from outside pithead while the guard is failed, the installed LAN binds still in .env:
    # restart policy "no" does not stop these, the entrypoint's gate does.
    # shellcheck disable=SC2086 # one argument per container
    rx "docker compose start $containers; docker compose up -d --no-deps $containers; docker start $containers; sleep 5" >/dev/null 2>&1 || true
    for p in "$@"; do
        assert_eq "compose start/up and docker start with the guard failed, port $p: a non-private source cannot connect (#2749)" \
            "$(_lan_probe 198.51.100 "$p")" closed
    done
    for c in $containers; do
        assert_eq "$c refused those starts, exit 78, before its daemon listened (#2749)" \
            "$(rx "docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' $c")" "false 78"
    done
    rx 'sudo rm -rf /run/systemd/system/pithead-lan-guard.service.d && sudo systemctl daemon-reload && sudo systemctl reset-failed pithead-lan-guard.service pithead-lan-hold.service' >/dev/null 2>&1 || true
    rc=0
    pithead up >/dev/null 2>&1 || rc=$?
    assert_rc "recovery: ./pithead up (#2749)" "$rc" "0"
    for c in $containers; do
        assert_eq "recovery: $c runs again (#2749)" "$(rx "docker inspect -f '{{.State.Running}}' $c")" "true"
    done
    for p in "$@"; do
        assert_eq "recovery, port $p: a non-private source cannot connect (#2749)" "$(_lan_probe 198.51.100 "$p")" closed
        assert_eq "recovery, port $p: a private source can (#2749)" "$(_lan_probe 10.254.254 "$p")" open
    done
    # Teardown keeps the rule when the nodes' marker cannot be deleted (#2749): a directory where the
    # marker file goes fails `rm -f`, even as root. Nothing is stopped; the marker is put back after.
    rc=0
    rx 'mv data/lan-guard/enforced data/lan-guard/enforced.keep-2749 && mkdir -p data/lan-guard/enforced/x' >/dev/null 2>&1 || true
    rx 'bash -c "source ./pithead && remove_lan_guard"' >/dev/null 2>&1 || rc=$?
    rx 'rm -rf data/lan-guard/enforced && mv data/lan-guard/enforced.keep-2749 data/lan-guard/enforced' >/dev/null 2>&1 || true
    assert_ne "remove_lan_guard fails when the marker cannot be deleted (#2749)" "$rc" "0"
    rc=0
    rx "bash -c 'source ./pithead && lan_guard_enforced $*'" >/dev/null 2>&1 || rc=$?
    assert_rc "...and the rule stays live (#2749)" "$rc" "0"
    assert_eq "...port $1: a non-private source still cannot connect (#2749)" "$(_lan_probe 198.51.100 "$1")" closed
}
