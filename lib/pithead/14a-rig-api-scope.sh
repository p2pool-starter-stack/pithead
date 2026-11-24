rig_is_paired() {
    [ "$(jq -r 'if has("paired") then .paired | tostring else "true" end' "$PWD/rig.json" 2>/dev/null)" != "false" ]
}

rig_own_subnets() {
    local def iface addr pfx o1 o2 o3 o4 mask n net first=""
    def=$(ip -4 -o route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    while read -r _ iface _ addr _; do
        case "$iface" in
            lo | docker0 | br-* | veth* | cni* | flannel* | lxc* | virbr*) continue ;;
        esac
        pfx=${addr#*/}
        IFS=. read -r o1 o2 o3 o4 <<<"${addr%/*}"
        [ "$o1" = 127 ] || { [ "$o1" = 169 ] && [ "$o2" = 254 ]; } && continue
        case "$pfx" in '' | *[!0-9]*) continue ;; esac
        [ "$pfx" -ge 8 ] && [ "$pfx" -le 32 ] || continue
        mask=$(((0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF))
        n=$((((o1 << 24) | (o2 << 16) | (o3 << 8) | o4) & mask))
        net="$((n >> 24 & 255)).$((n >> 16 & 255)).$((n >> 8 & 255)).$((n & 255))/$pfx"
        if [ "$iface" = "$def" ]; then
            echo "$net"
            return 0
        fi
        [ -n "$first" ] || first=$net
    done < <(ip -4 -o addr 2>/dev/null)
    [ -z "$first" ] || echo "$first"
}

rig_api_allow_from() {
    local override
    override=$(jq -r '.api_allow_from_override // ""' "$PWD/rig.json" 2>/dev/null)
    if [ -n "$override" ]; then
        echo "$override"
    elif rig_is_paired; then
        rig_coordinator_ip
    else
        rig_own_subnets
    fi
}

rig_allow_missing_reason() {
    if rig_is_paired; then
        echo "the pool host does not resolve to an IPv4 address to pin it to"
    else
        echo "no connected LAN subnet qualifies to pin it to"
    fi
}
