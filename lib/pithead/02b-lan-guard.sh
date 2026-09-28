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
# tests/stack/firewall/lan-guard.sh fails if one of those publishes stops being one.
LAN_GUARD_TAG="pithead-lan-guard"
LAN_GUARD_CHAIN="PITHEAD-LAN"
LAN_GUARD_NFT_TABLE="pithead_lan"
LAN_GUARD_SOURCES="127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10"
# <.env bind key>:<port>. The ports are fixed on both sides in docker-compose.yml and the quadlet units.
LAN_GUARD_BINDS="MONERO_RPC_BIND:18081 MONERO_ZMQ_BIND:18083 TARI_GRPC_BIND:18142"
# The host's boot id, kept only while the rule is live (#2749). The node entrypoints (./data/lan-guard,
# read-only) refuse a LAN bind unless it matches the running boot, so a reboot invalidates it. The
# boot unit's copy is root's, hence rm before the write.
LAN_GUARD_MARKER="data/lan-guard/enforced"
BOOT_ID_FILE="${PITHEAD_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
lan_guard_mark() { mkdir -p "${LAN_GUARD_MARKER%/*}" && rm -f "$LAN_GUARD_MARKER" && cat "$BOOT_ID_FILE" >"$LAN_GUARD_MARKER"; }
lan_guard_unmark() { rm -f "$LAN_GUARD_MARKER" 2>/dev/null || sudo -n rm -f "$LAN_GUARD_MARKER" 2>/dev/null; } # 1: still there
# A verb's teardown of the rule (#2749): remove_lan_guard, or stop the verb with the rule kept.
lan_guard_teardown() { # <verb>
    local rc=0 why="$LAN_GUARD_MARKER could not be deleted"
    remove_lan_guard || rc=$?
    [ "$rc" = 2 ] && why="monerod or tari may still be running (or the engine cannot say)"
    [ "$rc" = 0 ] || error "$1 stopped: $why, so the LAN-only source rule stays."
}

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
    6) printf 'the boot unit that restores it after a reboot could not be installed' ;;
    7) printf 'the marker the node containers check could not be written' ;;
    *) printf 'the readback failed (rc %s)' "$1" ;;
    esac
}

# Install the rule for every published node port, or hold those ports on loopback for this
# process. Called by compose_up, so it runs before every container (re)start.
apply_lan_guard() {
    local published kp ports=() old rc=0
    # Compose defaults to "no"; provision_lan_guard_boot_unit sets it where it counts. The nodes
    # bind-mount the marker dir, and podman does not create a missing bind source.
    export MONERO_RESTART=unless-stopped TARI_RESTART=unless-stopped
    mkdir -p "${LAN_GUARD_MARKER%/*}" 2>/dev/null || true
    published=$(lan_guard_published)
    if [ -z "$published" ]; then
        remove_lan_guard_boot_unit || warn "lan-guard:boot-unit-left — could not remove $LAN_GUARD_BOOT_UNIT/$LAN_GUARD_HOLD_UNIT; they keep the nodes held at boot until they are."
        return 0
    fi
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
    # A rule that cannot outlive a reboot (no boot unit), or that the nodes cannot see, is not installed.
    [ "$rc" = 0 ] && ! provision_lan_guard_boot_unit "${ports[@]}" && rc=6
    [ "$rc" = 0 ] && ! lan_guard_mark 2>/dev/null && rc=7
    if [ "$rc" = 0 ]; then
        log "LAN-only sources enforced on port(s) ${ports[*]}: loopback, private and CGNAT addresses only."
        return 0
    fi
    lan_guard_unmark || warn "lan-guard:marker-kept — could not delete $LAN_GUARD_MARKER."
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
    check_lan_guard_hold "${ports[@]}"
    lan_guard_enforced "${ports[@]}" || rc=$?
    if [ "$rc" = 0 ] && tor_egress_boot_unit_applies && ! systemctl is-enabled "$LAN_GUARD_BOOT_UNIT" >/dev/null 2>&1; then
        dr_warn_surface "LAN-only sources are enforced on port(s) ${ports[*]} now, but $LAN_GUARD_BOOT_UNIT is not enabled, so a reboot reopens them to every source until './pithead up'. Run './pithead up' to install it." "Node port(s) ${ports[*]} are limited to the LAN now, but that limit will not survive a restart of this machine."
        return 0
    fi
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

# doctor (#2749), DIY Docker with a LAN port published: a stopped node FAILs with why (held at boot,
# refused, exited) and the recovery; so does a running one Docker would restart at boot. Removed: none.
check_lan_guard_hold() { # <port>...
    tor_egress_boot_unit_applies || return 0
    local p c seen=" " policy why
    for p in "$@"; do
        c=$(lan_guard_container "$p")
        [[ "$seen" == *" $c "* ]] && continue
        seen+="$c "
        policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null) || continue
        if container_is_running "$c"; then
            [ "$policy" = no ] || dr_fail_surface "$c publishes a LAN port with restart policy '$policy', so after a reboot Docker starts it before the LAN-only source rule is back. Run './pithead up'." "$c could start after a restart before the rule that limits its LAN port is back."
            continue
        fi
        if systemctl is-failed --quiet "$LAN_GUARD_BOOT_UNIT" 2>/dev/null; then
            why="held since boot, because $LAN_GUARD_BOOT_UNIT failed and the LAN-only source rule is not in place (see 'journalctl -u $LAN_GUARD_BOOT_UNIT')"
        elif [ "$(docker inspect -f '{{.State.ExitCode}}' "$c" 2>/dev/null)" = 78 ]; then
            why="it refused to start because the LAN-only source rule was not in place"
        else
            why="it exited (code $(docker inspect -f '{{.State.ExitCode}}' "$c" 2>/dev/null)), and with LAN access on Docker does not restart it"
        fi
        dr_fail_surface "$c is down: $why. Run './pithead up' to start it." "$c is down and nothing restarts it by itself."
    done
}

# Nothing published, or every published port's rule live (#2749): `pithead restart` checks it.
lan_guard_ready() {
    local kp ports=()
    for kp in $(lan_guard_published); do ports+=("${kp#*:}"); done
    [ "${#ports[@]}" = 0 ] || lan_guard_enforced "${ports[@]}"
}

# Remove the rule from both backends (`sudo -n`: a leftover only drops traffic to an unpublished
# port, so no prompt). Kept, and 2, unless the engine answers and neither node runs, whatever the
# profiles or binds say now; kept, and 1, if the marker stays (#2749).
remove_lan_guard() {
    local line names
    names=$(docker ps --format '{{.Names}}' 2>/dev/null) || return 2
    ! grep -qxE 'monerod|tari' <<<"$names" || return 2
    lan_guard_unmark || return 1
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
# --- The same rule across a DIY host reboot (#2749) ----------------------------------------------
# pithead-lan-guard.service restores rule then marker before docker.service (as 02a). The nodes run
# restart "no"; pithead-lan-hold.service starts them after the guard (Requires=), so nothing restarts
# a crash (doctor, dashboard say so). The appliance needs neither: pithead-boot runs `up` first.
LAN_GUARD_BOOT_UNIT="pithead-lan-guard.service"
LAN_GUARD_HOLD_UNIT="pithead-lan-hold.service"

lan_guard_container() { if [ "$1" = 18142 ]; then echo tari; else echo monerod; fi; } # <port> -> its node

# The unit text for <iptables> <marker> <port>.... Fails closed: DROP first, RETURNs above it, jumps
# last, so a start that stops halfway drops every source. `-D` first: a restart does not stack jumps.
render_lan_guard_boot_unit() { # <iptables> <marker path> <port>...
    local ipt="$1" marker="$2" p lg_jump i
    shift 2
    local -a srcs
    read -r -a srcs <<<"$LAN_GUARD_SOURCES"
    cat <<EOF
[Unit]
Description=pithead LAN-only sources on the *_lan_access node ports, restored before containers start
Before=docker.service
# After firewall loaders (they could flush our rules) and the egress unit (our jumps land above it).
After=ufw.service firewalld.service netfilter-persistent.service nftables.service pithead-egress.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-$ipt -N DOCKER-USER
ExecStart=-$ipt -N $LAN_GUARD_CHAIN
ExecStart=$ipt -F $LAN_GUARD_CHAIN
ExecStart=$ipt -A $LAN_GUARD_CHAIN -j DROP
EOF
    for ((i = ${#srcs[@]} - 1; i >= 0; i--)); do
        printf 'ExecStart=%s -I %s 1 -s %s -j RETURN\n' "$ipt" "$LAN_GUARD_CHAIN" "${srcs[$i]}"
    done
    for p in "$@"; do
        lg_jump="-p tcp -m tcp --dport $p -m conntrack --ctstate NEW -m comment --comment $LAN_GUARD_TAG -j $LAN_GUARD_CHAIN"
        printf 'ExecStart=-%s -D DOCKER-USER %s\n' "$ipt" "$lg_jump"
        printf 'ExecStart=%s -I DOCKER-USER 1 %s\n' "$ipt" "$lg_jump"
    done
    # Last, so the nodes' marker is written only once every rule above is in: the current boot id.
    printf 'ExecStartPost=/bin/sh -c "rm -f %s && cat %s > %s"\n' "$marker" "$BOOT_ID_FILE" "$marker"
    cat <<EOF

[Install]
WantedBy=docker.service
EOF
}

# The hold unit for <docker> <iptables> <port>.... A failed guard never starts it (Requires=); a guard
# still "active" after the rule went fails the live -C checks. `-`: a removed container is no failure.
render_lan_guard_hold_unit() { # <docker> <iptables> <port>...
    local docker="$1" ipt="$2" p c containers=()
    shift 2
    for p in "$@"; do
        c=$(lan_guard_container "$p")
        [[ " ${containers[*]} " == *" $c "* ]] || containers+=("$c")
    done
    cat <<EOF
[Unit]
Description=pithead starts the *_lan_access node containers only once their LAN-only source rule is in place
Requires=$LAN_GUARD_BOOT_UNIT docker.service
After=$LAN_GUARD_BOOT_UNIT docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
EOF
    printf 'ExecStartPre=%s -C %s -j DROP\n' "$ipt" "$LAN_GUARD_CHAIN"
    for p in "$@"; do
        printf 'ExecStartPre=%s -C DOCKER-USER -p tcp -m tcp --dport %s -m conntrack --ctstate NEW -m comment --comment %s -j %s\n' \
            "$ipt" "$p" "$LAN_GUARD_TAG" "$LAN_GUARD_CHAIN"
    done
    for c in "${containers[@]}"; do printf 'ExecStart=-%s start %s\n' "$docker" "$c"; done
    cat <<EOF

[Install]
WantedBy=multi-user.target
EOF
}

# Write and enable <unit> with <text>, or leave it when it already matches and is enabled.
install_lan_guard_unit() { # <unit dir> <unit> <text>
    if [ "$(cat "$1/$2" 2>/dev/null)" = "$3" ] && systemctl is-enabled "$2" >/dev/null 2>&1; then
        return 0
    fi
    printf '%s\n' "$3" | sudo tee "$1/$2" >/dev/null &&
        sudo systemctl daemon-reload && sudo systemctl enable "$2" >/dev/null 2>&1
}

# Install both units for <port>... and hand compose restart "no"; 1 when either fails. Not --now.
provision_lan_guard_boot_unit() { # <port>...
    tor_egress_boot_unit_applies || return 0
    local ipt docker unit_dir p c containers=()
    ipt=$(command -v iptables) || return 1
    docker=$(command -v docker) || return 1
    unit_dir=$(control_unit_dir)
    for p in "$@"; do
        c=$(lan_guard_container "$p")
        [[ " ${containers[*]} " == *" $c "* ]] || containers+=("$c")
    done
    # The marker path goes into a unit command line: only a plain path, or no unit (loopback).
    [[ "$PWD" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    install_lan_guard_unit "$unit_dir" "$LAN_GUARD_BOOT_UNIT" "$(render_lan_guard_boot_unit "$ipt" "$PWD/$LAN_GUARD_MARKER" "$@")" &&
        install_lan_guard_unit "$unit_dir" "$LAN_GUARD_HOLD_UNIT" "$(render_lan_guard_hold_unit "$docker" "$ipt" "$@")" ||
        return 1
    for c in "${containers[@]}"; do
        if [ "$c" = tari ]; then export TARI_RESTART=no; else export MONERO_RESTART=no; fi
    done
    log "At boot, ${containers[*]} start only once the LAN-only source rule is back ($LAN_GUARD_HOLD_UNIT); Docker does not restart them by itself."
}

# Disable and delete both units (switches off, uninstall); 1 if a step fails or a unit or want stays.
remove_lan_guard_boot_unit() {
    local unit_dir lg_unit lg_removed=0 rc=0
    unit_dir=$(control_unit_dir)
    for lg_unit in "$LAN_GUARD_HOLD_UNIT" "$LAN_GUARD_BOOT_UNIT"; do
        [ -e "$unit_dir/$lg_unit" ] || continue
        sudo systemctl disable "$lg_unit" >/dev/null 2>&1 || rc=1
        sudo rm -f "$unit_dir/$lg_unit" || rc=1
        lg_removed=1
    done
    [ "$lg_removed" = 0 ] || sudo systemctl daemon-reload >/dev/null 2>&1 || rc=1
    [ ! -e "$unit_dir/$LAN_GUARD_HOLD_UNIT" ] && [ ! -e "$unit_dir/$LAN_GUARD_BOOT_UNIT" ] || rc=1
    ! systemctl show -p Wants --value docker.service multi-user.target 2>/dev/null | grep -qE 'pithead-lan-(guard|hold)\.service' || rc=1
    return "$rc"
}
