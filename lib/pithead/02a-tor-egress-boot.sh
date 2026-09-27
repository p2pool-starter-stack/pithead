# --- Tor-only egress across a DIY host reboot (#2460) --------------------------------------------
# DOCKER-USER lives in the kernel, so a reboot empties it, while every container comes back on its
# own (`restart: unless-stopped`) the moment dockerd starts. Nothing ran `pithead up` in between,
# so a DIY host rebooted into a mining stack with no fail-closed egress at all: production ran 17
# days that way, dashboard green. The appliance does not have this gap — pithead-boot runs `up`,
# which installs the firewall before compose — so this is the Docker/DIY path only.
#
# The fix is a oneshot unit ordered Before=docker.service and pulled in by it (WantedBy), so every
# docker start — boot, or socket activation — first puts the tagged rules into DOCKER-USER. Docker
# adopts an existing DOCKER-USER without flushing it and adds the FORWARD jump itself: the same
# mechanism the before-compose install in stack_up already relies on.
#
# The unit carries the rules INLINE, rendered from tor_egress_rules, and never calls this CLI:
# - no checkout path in it, so an upgrade's new versioned dir or a deleted sibling checkout cannot
#   strand it (the control-runner units needed an ownership protocol for exactly that);
# - no `docker` call, which under socket activation would wait on docker.service, which waits on
#   this unit: a boot-time deadlock.
# The rules are box-global (one tag, one chain), so the unit is too: the last apply writes it, as
# the last apply writes the live rules.
TOR_EGRESS_BOOT_UNIT="pithead-egress.service"

# The unit text for <iptables path> <subnet> <tor_ip>. Pure (args only) so it unit-tests.
#
# Inserts run in REVERSE, each at position 1: the DROP goes in first and every ACCEPT lands above
# it. If an insert fails halfway, systemd stops at that line with the DROP already live, so a
# partial install over-blocks instead of opening the box. The `-D` lines first make a manual
# restart idempotent (a start with the rules already present replaces rather than stacks them);
# the `-` prefix lets them fail when the rule is absent, which at boot it always is.
render_tor_egress_boot_unit() { # <iptables> <subnet> <tor_ip>
    local ipt="$1" rule i
    local -a rules
    mapfile -t rules < <(tor_egress_rules "$2" "$3")
    cat <<EOF
[Unit]
Description=pithead Tor-only egress firewall, restored before Docker starts containers
Before=docker.service
# A firewall manager that loads after us could flush what we insert.
After=ufw.service firewalld.service netfilter-persistent.service nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-$ipt -N DOCKER-USER
EOF
    for rule in "${rules[@]}"; do
        printf 'ExecStart=-%s -D DOCKER-USER -m comment --comment %s %s\n' "$ipt" "$TOR_EGRESS_TAG" "$rule"
    done
    for ((i = ${#rules[@]} - 1; i >= 0; i--)); do
        printf 'ExecStart=%s -I DOCKER-USER 1 -m comment --comment %s %s\n' "$ipt" "$TOR_EGRESS_TAG" "${rules[$i]}"
    done
    cat <<EOF

[Install]
WantedBy=docker.service
EOF
}

# Where this host needs the boot unit: a systemd DIY host on Docker. The appliance (podman +
# netavark, its own boot path) and hosts without systemd never get one.
tor_egress_boot_unit_applies() {
    [ "$OS_TYPE" == "Linux" ] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    ! is_appliance || return 1
    [ "$(container_engine)" = docker ]
}

# Write and enable the unit, or leave it when it already matches and is enabled, which keeps a
# routine apply from reloading systemd. Enable, not --now: the live rules are apply's job, and
# starting the unit here would insert them a second time.
provision_tor_egress_boot_unit() { # <subnet> <tor_ip>
    tor_egress_boot_unit_applies || return 0
    local ipt unit_dir want
    ipt=$(command -v iptables) || return 0
    unit_dir=$(control_unit_dir)
    want=$(render_tor_egress_boot_unit "$ipt" "$1" "$2")
    if [ "$(cat "$unit_dir/$TOR_EGRESS_BOOT_UNIT" 2>/dev/null)" = "$want" ] &&
        systemctl is-enabled "$TOR_EGRESS_BOOT_UNIT" >/dev/null 2>&1; then
        return 0
    fi
    if printf '%s\n' "$want" | sudo tee "$unit_dir/$TOR_EGRESS_BOOT_UNIT" >/dev/null &&
        sudo systemctl daemon-reload && sudo systemctl enable "$TOR_EGRESS_BOOT_UNIT" >/dev/null 2>&1; then
        log "Tor-egress firewall will be restored at boot, before Docker starts the containers ($TOR_EGRESS_BOOT_UNIT)."
    else
        warn "egress-boot:unit-install-failed — could not install $TOR_EGRESS_BOOT_UNIT. The firewall is live now, but a host reboot will bring the containers back WITHOUT it until './pithead up' runs."
    fi
}

# Disable and delete the unit (opt-out, uninstall). Only our unit name, never another firewall's.
remove_tor_egress_boot_unit() {
    local unit_dir
    unit_dir=$(control_unit_dir)
    [ -e "$unit_dir/$TOR_EGRESS_BOOT_UNIT" ] || return 0
    sudo systemctl disable "$TOR_EGRESS_BOOT_UNIT" >/dev/null 2>&1 || true
    sudo rm -f "$unit_dir/$TOR_EGRESS_BOOT_UNIT" || true
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
}
