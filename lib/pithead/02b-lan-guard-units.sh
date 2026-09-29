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
    # An unreadable want list is not an empty one.
    if command -v systemctl >/dev/null 2>&1; then
        lg_unit=$(systemctl show -p Wants --value docker.service multi-user.target 2>/dev/null) || rc=1
        ! grep -qE 'pithead-lan-(guard|hold)\.service' <<<"$lg_unit" || rc=1
    fi
    return "$rc"
}
