# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The worker-descriptor SSRF floor, second half (#2671): this machine's OWN addresses. The first
# half (test-control-add-only-ssrf.sh) refuses the fixed classes — loopback, link-local, the stack's
# own bridge. This battery proves the gate also refuses every address on this host's interfaces and
# every address behind one of its container bridges, and still lets a LAN neighbour through to the
# ordinary descriptor refusal.
#
# SHARED FIXTURES. gate_try(), $UUID5, $REQS and $RESULTS come from test-control-add-only-ssrf.sh,
# which run.sh sources before this file and which leaves them defined on purpose (its own header).
# The real interface list is whatever the CI runner has, so a fake `ip` goes on $C/bin — already on
# PATH for every gate_try — and answers from the fixture below: a LAN NIC, docker0, a user-defined
# br- network on a /21 with an IPv6 subnet, a LAN bridge br0 that carries the default route, and a
# point-to-point tunnel whose address has no prefix. A fake `getent` answers the named cases.
#
# MUTATION PROOF: dropping _host_local_networks from _control_host_is_internal reddens every
# "refused" row; dropping the bridge-subnet line reddens the container rows; dropping the
# default-route exception reddens the LAN-bridge neighbour row; checking only the literal branch
# reddens the resolved-name rows; a nibble-only prefix match reddens the /21 rows; failing open on an
# unreadable address or bridge list reddens the last two.
: "${UUID5:?test-control-add-only-ssrf.sh must run first}"
declare -F gate_try >/dev/null || bad "gate_try is defined" "test-control-add-only-ssrf.sh must run first"

echo "== black-box: the worker SSRF floor refuses this host's own addresses and bridges (#2671) =="
cat >"$C/bin/ip" <<IP_STUB
#!/usr/bin/env bash
# Test-only interface list for #2671 (tests/stack/control/test-control-ssrf-host-local.sh).
[ -e "$C/ip-fails" ] && exit 1
[ -e "$C/ip-bridges-fail" ] && [ "\$*" = "-o link show type bridge" ] && exit 2
case "\$*" in
"-o addr show")
    cat <<'ADDRS'
1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
1: lo    inet6 ::1/128 scope host \       valid_lft forever preferred_lft forever
2: eth0    inet 192.168.1.20/24 brd 192.168.1.255 scope global eth0\       valid_lft forever preferred_lft forever
2: eth0    inet6 2001:db8:1::20/64 scope global \       valid_lft forever preferred_lft forever
3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\       valid_lft forever preferred_lft forever
4: br-0a1b2c3d4e5f    inet 172.19.0.1/21 brd 172.19.7.255 scope global br-0a1b2c3d4e5f\       valid_lft forever preferred_lft forever
4: br-0a1b2c3d4e5f    inet6 fd00:dead::1/64 scope global \       valid_lft forever preferred_lft forever
5: br0    inet 10.20.0.2/24 brd 10.20.0.255 scope global br0\       valid_lft forever preferred_lft forever
6: wg0    inet 10.99.0.1 peer 10.99.0.2/32 scope global wg0\       valid_lft forever preferred_lft forever
ADDRS
    ;;
"-o link show type bridge")
    printf '%s\n' "3: docker0: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT" \
        "4: br-0a1b2c3d4e5f: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT" \
        "5: br0: <BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state UP mode DEFAULT"
    ;;
"-4 route show default") echo "default via 10.20.0.1 dev br0 proto dhcp src 10.20.0.2 metric 100" ;;
"-6 route show default") echo "default via fe80::1 dev br0 proto ra metric 100 pref medium" ;;
*) exit 1 ;;
esac
IP_STUB
cat >"$C/bin/getent" <<'GETENT_STUB'
#!/usr/bin/env bash
# Test-only DNS answers for #2671: "<name> -> <address>".
case "$1 $2" in
"ahosts own-lan-name") ip=192.168.1.20 ;;
"ahosts own-v6-name") ip=2001:db8:1::20 ;;
"ahosts mapped-own-name") ip=::ffff:192.168.1.20 ;;
"ahosts bridge-v6-name") ip=fd00:dead::42 ;;
"ahosts lan-v6-neighbour") ip=2001:db8:1::21 ;;
*) exec /usr/bin/getent "$@" ;;
esac
printf '%s STREAM %s\n' "$ip" "$2"
GETENT_STUB
chmod +x "$C/bin/ip" "$C/bin/getent"
hl_rigs=$(jq -c '.workers.list // []' "$C/config.json")

hl_try() { # <host>
    jq --arg h "$1" '.workers.list += [{name:"evil-local",host:$h,control_port:8000,token:"attacker"}]' "$C/config.json" >"$C/cand.json"
    gate_try "$C/cand.json"
}
assert_host_local_refused() { # <host> <label>
    hl_try "$1"
    assert_eq "new-rig append pointed at $2 is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
    assert_contains "new-rig append pointed at $2 names the host boundary" \
        "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "resolves inside this host"
}
assert_lan_neighbour_passes_floor() { # <host> <label>
    hl_try "$1"
    assert_not_contains "new-rig append pointed at $2 clears the host floor" \
        "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "resolves inside this host"
    assert_contains "new-rig append pointed at $2 still meets the descriptor refusal" \
        "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "worker descriptor"
}
assert_host_local_refused "192.168.1.20" "this host's own LAN address"
assert_host_local_refused "172.17.0.1" "the docker0 gateway"
assert_host_local_refused "172.17.3.9" "a container behind docker0"
assert_host_local_refused "172.19.7.200" "a container at the top of a /21 bridge network"
assert_host_local_refused "10.20.0.2" "this host's own address on a LAN bridge"
assert_host_local_refused "10.99.0.1" "this host's own point-to-point tunnel address"
assert_host_local_refused "own-lan-name" "a name resolving to this host's LAN address"
assert_host_local_refused "own-v6-name" "a name resolving to this host's own IPv6 address"
assert_host_local_refused "mapped-own-name" "a name resolving to an IPv4-mapped copy of this host's address"
assert_host_local_refused "bridge-v6-name" "a name resolving into a bridge's IPv6 subnet"
assert_lan_neighbour_passes_floor "192.168.1.21" "a LAN neighbour on the NIC's subnet"
assert_lan_neighbour_passes_floor "10.20.0.50" "a LAN neighbour behind the default-route bridge"
assert_lan_neighbour_passes_floor "172.19.8.1" "the first address past a /21 bridge network"
assert_lan_neighbour_passes_floor "lan-v6-neighbour" "an IPv6 LAN neighbour"
: >"$C/ip-fails"
assert_host_local_refused "192.168.1.21" "a LAN neighbour while the interface list is unreadable (fail-closed)"
rm -f "$C/ip-fails"
: >"$C/ip-bridges-fail"
assert_host_local_refused "192.168.1.21" "a LAN neighbour while the bridge list is unreadable (fail-closed)"
assert_eq "config.json gains no descriptor from the #2671 battery" "$(jq -c '.workers.list // []' "$C/config.json")" "$hl_rigs"

rm -f "$C/bin/ip" "$C/bin/getent" "$C/ip-bridges-fail"
unset -f hl_try assert_host_local_refused assert_lan_neighbour_passes_floor
unset hl_rigs
