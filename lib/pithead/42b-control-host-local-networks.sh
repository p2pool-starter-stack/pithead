# The worker-descriptor SSRF floor's second half (#2671): this machine's OWN addresses. The first
# half (_ipv4_is_sensitive/_ipv6_is_sensitive, 42-control-policy-and-host-checks.sh) refuses the
# address classes that are "this host" on every machine — loopback, link-local, the stack's own
# bridge. It could not see the addresses that are this host on THIS machine only: its LAN address,
# the engine's default bridge (docker0/podman0) and every other bridge network on the box. A
# workers.list[] host pointed at one of those passed the floor, and worker-apply/worker-upgrade then
# dialed it from the host with a bearer the request writer chose. Since #2641 a dashboard adopt can
# commit behind the typed APPLY, so this floor is the only host-side check left between a
# compromised dashboard container and that dial.
#
# Two rules, because the two kinds of interface mean different things:
#   - every address on every interface is refused EXACTLY: the LAN address is this host, but its
#     LAN neighbours are the rigs this feature exists to reach, so the LAN subnet stays allowed;
#   - a bridge interface is refused as a WHOLE SUBNET: everything behind docker0 or a br-* network
#     is a container on this machine, never a separate rig.
# The one bridge that is not a container network is a LAN bridge (a NIC enslaved to br0 on a VM
# host). It carries the default route and container bridges never do, so a bridge that carries it
# falls back to the exact-address rule instead of refusing the operator's whole LAN.
#
# Engine-free, like appliance_mdns_interfaces (31a-): `ip` names every bridge the engine created
# without asking docker or podman, so a slow engine cannot shrink the list.

# Prints this host's own networks, one "<address> <prefix-bits>" per line: the full address length
# for an exact address, the interface's prefix for a bridge subnet. Non-zero when `ip` fails or
# lists nothing (every Linux host has at least loopback): the caller then FAILS CLOSED, because an
# unknown interface list can never prove a host is not this machine. This is the one seam a test
# replaces: a fake `ip` ahead of the real one on $PATH (tests/stack/control/test-control-ssrf-host-local.sh).
_host_local_networks() {
    local listing bridges routed
    listing=$(ip -o addr show 2>/dev/null) && [ -n "$listing" ] || return 1
    bridges=" $(ip -o link show type bridge 2>/dev/null | sed 's/^[0-9]*: *//; s/[:@].*//' | tr '\n' ' ') "
    routed=" $({
        ip -4 route show default
        ip -6 route show default
    } 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' | tr '\n' ' ') "
    awk -v bridges="$bridges" -v routed="$routed" '
        $3 != "inet" && $3 != "inet6" { next }
        {
            dev = $2; sub(/@.*/, "", dev)
            addr = $4; bits = ($3 == "inet") ? 32 : 128
            if (addr ~ /\//) { prefix = addr; sub(/.*\//, "", prefix); sub(/\/.*/, "", addr) } else prefix = bits
            print addr, bits
            if (index(bridges, " " dev " ") && !index(routed, " " dev " ")) print addr, prefix
        }' <<<"$listing"
}

# Prints an address as a fixed-width hex string: 8 digits for a canonical IPv4 literal, 32 for an
# IPv6 literal (any valid spelling, "::" expanded, a zone ID dropped). Non-zero for any other shape.
# One width per family lets _hex_prefix_match compare either family with the same code.
_ip_hex() {
    local a b c d v6 head tail h out="" i gap
    if _is_canonical_ipv4 "$1"; then
        IFS=. read -r a b c d <<<"$1"
        printf '%02x%02x%02x%02x' "$a" "$b" "$c" "$d"
        return 0
    fi
    v6="${1,,}"
    v6="${v6%%%*}"
    [[ "$v6" =~ ^[0-9a-f:]+$ ]] || return 1
    if [[ "$v6" == *::* ]]; then head="${v6%%::*}" tail="${v6#*::}"; else head="$v6" tail=""; fi
    [[ "$tail" != *::* ]] || return 1
    local -a hs=() ts=()
    [ -z "$head" ] || IFS=: read -r -a hs <<<"$head"
    [ -z "$tail" ] || IFS=: read -r -a ts <<<"$tail"
    gap=$((8 - ${#hs[@]} - ${#ts[@]}))
    if [[ "$v6" == *::* ]]; then [ "$gap" -ge 1 ] || return 1; else [ "$gap" -eq 0 ] || return 1; fi
    for h in "${hs[@]}"; do
        [[ "$h" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        out+=$(printf '%04x' "0x$h")
    done
    for ((i = 0; i < gap; i++)); do out+="0000"; done
    for h in "${ts[@]}"; do
        [[ "$h" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        out+=$(printf '%04x' "0x$h")
    done
    printf '%s' "$out"
}

# True if two same-family _ip_hex strings share their first <bits> bits.
_hex_prefix_match() { # <hex> <hex> <bits>
    [ "${#1}" -eq "${#2}" ] || return 1
    local n=$(($3 / 4)) r=$(($3 % 4)) mask
    [ "${1:0:n}" = "${2:0:n}" ] || return 1
    [ "$r" -eq 0 ] && return 0
    mask=$(((0xf << (4 - r)) & 0xf))
    [ $((0x${1:n:1} & mask)) -eq $((0x${2:n:1} & mask)) ]
}

# True if an address is one of this host's own (see the header), given the _host_local_networks
# listing. An IPv4-mapped IPv6 literal is checked by its embedded IPv4 address, which is what a dial
# reaches, for the same reason _ipv6_is_sensitive unwraps it. An address shape _ip_hex does not
# know is treated as local: the caller has already refused every shape it cannot classify.
_ip_in_host_networks() { # <ip> <listing>
    local ip="${1,,}" hex net bits nhex
    case "$ip" in ::ffff:*.*.*.*) ip="${ip##*:}" ;; esac
    hex=$(_ip_hex "$ip") || return 0
    while read -r net bits; do
        [ -n "$net" ] || continue
        nhex=$(_ip_hex "$net") || continue
        _hex_prefix_match "$hex" "$nhex" "$bits" && return 0
    done <<<"$2"
    return 1
}
