# --- LAN-only sources for the node ports the *_lan_access switches publish (#2616) --------------
# monero.rpc_lan_access, monero.zmq_lan_access and tari.grpc_lan_access publish 18081, 18083 and
# 18142 on 0.0.0.0, every host interface. The switches mean LAN, so a NEW connection to one of those
# ports from anything but loopback, RFC1918 or CGNAT (100.64.0.0/10, where Tailscale lives) is
# dropped. Binding to "the LAN address" instead would break on the next DHCP lease.
#
# Independent of network.tor_egress_firewall: that switch is about what leaves the stack, this one
# about what reaches it. It FAILS CLOSED: compose_up installs the rule before every `docker compose
# up`, and when it cannot (no root, no nft/iptables, the readback disagrees) the published binds are
# exported as 127.0.0.1 for that compose run, so the node never listens on 0.0.0.0 without it.
# Removed at `down` next to the egress rules. doctor reads the same lan_guard_enforced().
#
# Same two backends as the egress firewall. Docker DNATs a published port in PREROUTING, so the
# packet reaches FORWARD -> DOCKER-USER with the container's port (published P:P, so the same number):
# a tagged jump per port hands NEW connections to our own chain, which RETURNs the allowed sources
# and drops the rest. RETURN, not ACCEPT, so a stack container's own dial to a remote node's 18081
# still meets the egress rules below. On podman/netavark, an independent `inet pithead_lan` table
# hooked at forward priority -5, like pithead_egress; netavark never jumps to DOCKER-USER.
#
# IPv4 only, because the publishes are: every bind is an explicit IPv4 address, and
# tests/stack/test-lan-guard.sh fails if one of those publishes stops being an explicit IPv4 bind.
LAN_GUARD_TAG="pithead-lan-guard"
LAN_GUARD_CHAIN="PITHEAD-LAN"
LAN_GUARD_NFT_TABLE="pithead_lan"
LAN_GUARD_SOURCES="127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10"
# <.env bind key>:<port>. The ports are fixed on both sides in docker-compose.yml and the quadlet units.
LAN_GUARD_BINDS="MONERO_RPC_BIND:18081 MONERO_ZMQ_BIND:18083 TARI_GRPC_BIND:18142"

# The key:port pairs whose .env bind is anything but loopback, one per line.
lan_guard_published() {
    local kp
    for kp in $LAN_GUARD_BINDS; do
        case "$(env_get "${kp%%:*}" 2>/dev/null)" in '' | 127.0.0.1) ;; *) printf '%s\n' "$kp" ;; esac
    done
}

# `iptables-restore --noflush` input for <port>...: declaring our chain flushes and refills it, the
# stale tagged jumps (<old jump spec> lines on stdin, as `iptables -S` prints them) are deleted and
# the new ones inserted at the top of DOCKER-USER, all in one commit, so no packet sees a half-built
# set. Pure (args + stdin) so it unit-tests.
render_lan_guard_iptables() { # <port>... < old tagged DOCKER-USER lines
    local s p line
    # The explicit -F: legacy and nft iptables-restore do not agree on whether a declaration alone
    # flushes an existing chain under --noflush.
    printf '%s\n' "*filter" ":$LAN_GUARD_CHAIN - [0:0]" "-F $LAN_GUARD_CHAIN"
    for s in $LAN_GUARD_SOURCES; do printf '%s\n' "-A $LAN_GUARD_CHAIN -s $s -j RETURN"; done
    printf '%s\n' "-A $LAN_GUARD_CHAIN -j DROP"
    while IFS= read -r line; do
        [ -n "$line" ] && printf '%s\n' "-D ${line#-A }"
    done
    for p in "$@"; do
        printf '%s\n' "-I DOCKER-USER 1 -p tcp -m tcp --dport $p -m conntrack --ctstate NEW -m comment --comment $LAN_GUARD_TAG -j $LAN_GUARD_CHAIN"
    done
    printf '%s\n' "COMMIT"
}

# `nft -f` ruleset for <port>... on the podman path; add+delete+define is one atomic replace.
render_lan_guard_nft() { # <port>...
    local ports srcs
    ports=$(printf '%s, ' "$@")
    # shellcheck disable=SC2086  # one set element per source
    srcs=$(printf '%s, ' $LAN_GUARD_SOURCES)
    printf '%s\n' \
        "add table inet $LAN_GUARD_NFT_TABLE" \
        "delete table inet $LAN_GUARD_NFT_TABLE" \
        "table inet $LAN_GUARD_NFT_TABLE {" \
        "  chain forward {" \
        "    type filter hook forward priority -5; policy accept;" \
        "    tcp dport { ${ports%, } } ct state new ip saddr != { ${srcs%, } } drop" \
        "  }" \
        "}"
}

# Is the rule for every <port> live? Same return codes as tor_egress_enforced: 0 enforced, 1 not in
# the ruleset, 2 the backend's tool is missing, 3 unreadable (no passwordless sudo), 4 installed in
# DOCKER-USER but nothing jumps there, 5 a foreign ACCEPT/RETURN sits above our jumps.
lan_guard_enforced() { # <port>...
    local out p line
    if [ "$(container_engine)" = "podman" ]; then
        command -v nft >/dev/null 2>&1 || return 2
        command -v jq >/dev/null 2>&1 || return 3
        sudo -n nft list tables >/dev/null 2>&1 || return 3
        out=$(sudo -n nft -j list table inet "$LAN_GUARD_NFT_TABLE" 2>/dev/null) || return 1
        # A drop rule IN the forward-hooked chain that names every port.
        jq -e --arg ports "$*" '
            [.nftables[] | select(has("chain")) | select(.chain.hook == "forward") | .chain.name] as $h
            | [.nftables[] | select(has("rule")) | select(.rule.chain as $c | $h | index($c))
               | .rule.expr | select(any(has("drop"))) | tostring]
            | any(. as $r | $ports | split(" ") | all(. as $p | $r | test("[^0-9]" + $p + "[^0-9]")))
        ' >/dev/null 2>&1 <<<"$out" || return 1
        return 0
    fi
    command -v iptables >/dev/null 2>&1 || return 2
    sudo -n iptables -S >/dev/null 2>&1 || return 3
    out=$(sudo -n iptables -S "$LAN_GUARD_CHAIN" 2>/dev/null) || return 1
    [ "$(printf '%s\n' "$out" | tail -n 1)" = "-A $LAN_GUARD_CHAIN -j DROP" ] || return 1
    out=$(sudo -n iptables -S DOCKER-USER 2>/dev/null) || return 1
    for p in "$@"; do
        grep -qE -- "--dport $p .*$LAN_GUARD_TAG.* -j $LAN_GUARD_CHAIN\$" <<<"$out" || return 1
    done
    # First match wins: a foreign ACCEPT/RETURN above our jumps decides first. The egress rules
    # above them never match a NEW inbound connection from outside the mining subnet.
    while IFS= read -r line; do
        case "$line" in
        *"$LAN_GUARD_TAG"*) break ;;
        -N* | -P* | *"$TOR_EGRESS_TAG"*) ;;
        *" -j ACCEPT"* | *" -j RETURN"*) return 5 ;;
        esac
    done <<<"$out"
    out=$(sudo -n iptables -S FORWARD 2>/dev/null) || return 4
    grep -qF -- '-j DOCKER-USER' <<<"$out" || return 4
    return 0
}

# Why lan_guard_enforced said no, for warn and doctor.
lan_guard_reason() { # <rc>
    case "$1" in
    1) printf 'the rule is not in the live ruleset' ;;
    2) printf 'the %s command is not installed' "$([ "$(container_engine)" = podman ] && echo nft || echo iptables)" ;;
    3) printf 'installing or reading it needs root (passwordless sudo)' ;;
    4) printf 'nothing jumps from FORWARD to DOCKER-USER' ;;
    5) printf 'a firewall rule that is not ours accepts traffic above it in DOCKER-USER' ;;
    *) printf 'the readback failed (rc %s)' "$1" ;;
    esac
}

# Install the rule for every published node port, or hold those ports on loopback for this
# process. Called by compose_up, so it runs before every container (re)start.
apply_lan_guard() {
    local published kp ports=() old rc=0
    published=$(lan_guard_published)
    [ -n "$published" ] || return 0
    for kp in $published; do ports+=("${kp#*:}"); done
    if [ "$(container_engine)" = "podman" ]; then
        if ! command -v nft >/dev/null 2>&1 || ! render_lan_guard_nft "${ports[@]}" | sudo nft -f - 2>/dev/null; then rc=2; fi
    elif ! command -v iptables-restore >/dev/null 2>&1; then
        rc=2
    else
        # DOCKER-USER may not exist before Docker's first network; declaring it in the restore
        # would flush it, so pre-create it the way apply_tor_egress_iptables does.
        sudo iptables -N DOCKER-USER 2>/dev/null || true
        old=$(sudo iptables -S DOCKER-USER 2>/dev/null | grep -F -- "$LAN_GUARD_TAG") || true
        render_lan_guard_iptables "${ports[@]}" <<<"$old" | sudo iptables-restore --noflush 2>/dev/null || rc=2
    fi
    if [ "$rc" = 0 ]; then
        lan_guard_enforced "${ports[@]}" || rc=$?
        # 4 before the first network exists: Docker adds the FORWARD jump when compose creates it.
        [ "$rc" = 4 ] && rc=0
    fi
    if [ "$rc" = 0 ]; then
        log "LAN-only sources enforced on port(s) ${ports[*]}: loopback, private and CGNAT addresses only."
        return 0
    fi
    for kp in $published; do export "${kp%%:*}=127.0.0.1"; done
    warn "lan-guard:not-installed — could not enforce LAN-only sources on port(s) ${ports[*]} ($(lan_guard_reason "$rc")). Holding them on 127.0.0.1 until it can; see './pithead doctor'."
}

# doctor (#2616): a *_lan_access switch publishes its node port only behind the LAN-only source rule
# (above). Rule live: OK. Rule missing while the container still publishes
# on 0.0.0.0 (rules lost at a reboot, or flushed): FAIL. Rule missing and the port held on loopback,
# which is what compose_up does when it cannot install the rule: WARN with the reason.
check_lan_guard() {
    local published kp ports=() exposed=() rc=0 c running=0
    published=$(lan_guard_published)
    [ -n "$published" ] || return 0
    for kp in $published; do ports+=("${kp#*:}"); done
    lan_guard_enforced "${ports[@]}" || rc=$?
    if [ "$rc" = 0 ]; then
        dr_ok "LAN-only sources enforced on port(s) ${ports[*]}: loopback, private and CGNAT addresses only."
        return 0
    fi
    for kp in $published; do
        c=monerod
        [ "${kp#*:}" = 18142 ] && c=tari
        container_is_running "$c" || continue
        running=1
        docker port "$c" "${kp#*:}/tcp" 2>/dev/null | grep -qv '^127\.0\.0\.1:' && exposed+=("${kp#*:}")
    done
    if [ "$running" = 0 ]; then
        dr_info "LAN-only source check skipped — the node containers aren't running."
    elif [ "${#exposed[@]}" -gt 0 ]; then
        dr_fail_surface "Port(s) ${exposed[*]} are published on every interface with NO LAN-only source rule ($(lan_guard_reason "$rc")), so any address that can route to this host can connect. Run './pithead up' to reinstall it." "Node port(s) ${exposed[*]} are open to every network, not just the LAN: the rule that limits them is missing ($(lan_guard_reason "$rc")). Restarting this machine reinstalls it."
    else
        dr_warn_surface "LAN access is on for port(s) ${ports[*]}, but they are held on 127.0.0.1: the LAN-only source rule cannot be installed ($(lan_guard_reason "$rc")). Fix that and run './pithead up'." "LAN access is on for node port(s) ${ports[*]}, but they are only reachable from this machine: the rule that limits them to the LAN cannot be installed ($(lan_guard_reason "$rc"))."
    fi
    return 0
}

# Remove the rule from both backends. `sudo -n`: a leftover rule only drops outside traffic to a
# port nothing publishes any more, so a host without passwordless sudo is not prompted for it.
remove_lan_guard() {
    local line
    if command -v nft >/dev/null 2>&1; then
        sudo -n nft delete table inet "$LAN_GUARD_NFT_TABLE" 2>/dev/null || true
    fi
    command -v iptables >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
        # Word-split, so drop the quotes `-S` may put around the comment: they would reach -D literally.
        line="${line//\"/}"
        # shellcheck disable=SC2086  # intentional word-splitting of the saved rule spec
        [ -n "$line" ] && sudo -n iptables -D DOCKER-USER ${line#-A DOCKER-USER } 2>/dev/null
    done < <(sudo -n iptables -S DOCKER-USER 2>/dev/null | grep -F -- "$LAN_GUARD_TAG" || true)
    sudo -n iptables -F "$LAN_GUARD_CHAIN" 2>/dev/null || true
    sudo -n iptables -X "$LAN_GUARD_CHAIN" 2>/dev/null || true
    return 0
}
