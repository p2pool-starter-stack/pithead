# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Tor-egress across a DIY host REBOOT (#2460): DOCKER-USER is emptied by a reboot while every
# container comes back on its own, so the rules must be restored by a boot unit ordered ahead of
# docker.service. These pin the unit's ordering, what running its ExecStart lines leaves in the
# chain (fresh boot, manual restart, a foreign rule, an insert failing halfway), that
# apply/opt-out/uninstall own the unit, and that doctor warns when it is missing. Self-contained
# stubs, like test-tor-egress-enforcement.sh, so run.sh's source order cannot matter.
# Sourced by tests/stack/run.sh.

EB="$SANDBOX/egress-boot"
mkdir -p "$EB/bin" "$EB/units"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$EB/bin/sudo"
printf '#!/usr/bin/env bash\necho Linux\n' >"$EB/bin/uname" # OS_TYPE is read when pithead is sourced
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/ipt.log"\n' "$EB" >"$EB/bin/iptables"
printf '#!/usr/bin/env bash\nexit 0\n' >"$EB/bin/iptables-save"
printf '#!/usr/bin/env bash\nexit 0\n' >"$EB/bin/nft"
# systemctl logs every call; `is-enabled` answers from SYSTEMCTL_ENABLED (default: not enabled).
cat >"$EB/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$EB/systemctl.log"
[ "\$1" = is-enabled ] && exit "\${SYSTEMCTL_ENABLED:-1}"
exit 0
EOF
chmod +x "$EB"/bin/*
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$EB/.env"
eb_run() {
    PITHEAD_ENGINE="${EB_ENGINE:-docker}" PITHEAD_APPLIANCE="${EB_APPLIANCE:-0}" PITHEAD_UNIT_DIR="$EB/units" \
        PATH="$EB/bin:$PATH" run_sourced "$EB" "$@"
}
EB_UNIT="$EB/units/pithead-egress.service"

echo "== unit: render_tor_egress_boot_unit — ordered ahead of docker, pulled in by it (#2460) =="
BU=$(run_sourced "$SANDBOX" render_tor_egress_boot_unit /usr/sbin/iptables 172.28.0.0/24 172.28.0.25)
assert_contains "runs before docker.service starts the containers" "$BU" "Before=docker.service"
assert_contains "every docker start pulls it in (boot and socket activation)" "$BU" "WantedBy=docker.service"
assert_contains "runs after the host's own firewall loaders, so they cannot flush it" "$BU" \
    "After=ufw.service firewalld.service netfilter-persistent.service nftables.service"
assert_contains "a oneshot that stays active" "$BU" "RemainAfterExit=yes"
assert_contains "pre-creates DOCKER-USER, tolerating an existing chain" "$BU" "ExecStart=-/usr/sbin/iptables -N DOCKER-USER"
assert_eq "the DROP is the FIRST insert, so a half-finished start fails closed" \
    "$(printf '%s\n' "$BU" | grep -m1 -- ' -I ')" \
    "ExecStart=/usr/sbin/iptables -I DOCKER-USER 1 -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP"
assert_eq "an insert failure fails the unit (no '-' prefix on any insert)" "$(printf '%s\n' "$BU" | grep -c '^ExecStart=-.* -I ')" "0"
assert_eq "every ExecStart runs iptables and nothing else (no checkout path, no socket-activation deadlock)" \
    "$(printf '%s\n' "$BU" | grep '^ExecStart=' | grep -vc '^ExecStart=-\{0,1\}/usr/sbin/iptables ')" "0"
assert_contains "honours a custom subnet (#180)" \
    "$(run_sourced "$SANDBOX" render_tor_egress_boot_unit /sbin/iptables 172.30.5.0/24 172.30.5.25)" "-s 172.30.5.0/24 -j DROP"

# Run the unit's ExecStart lines the way systemd does — in order, a `-` line may fail, any other
# failure stops the unit — against a model DOCKER-USER chain file (top rule first). FAIL_AT=<n>
# makes the n-th insert fail.
eb_boot() { # <unit text> <chain file>
    local unit="$1" chain="$2" line cmd tolerant n=0 spec
    local -a w
    while IFS= read -r line; do
        case "$line" in ExecStart=*) ;; *) continue ;; esac
        cmd="${line#ExecStart=}" tolerant=0
        case "$cmd" in -*) tolerant=1 cmd="${cmd#-}" ;; esac
        read -r -a w <<<"$cmd"
        case "${w[1]}" in
        -N) ;;
        -I)
            n=$((n + 1))
            [ "$n" != "${FAIL_AT:-0}" ] || return 1
            spec="${w[*]:4}"
            {
                printf '%s\n' "$spec"
                cat "$chain"
            } >"$chain.new" && mv "$chain.new" "$chain"
            ;;
        -D)
            spec="${w[*]:3}"
            if grep -qxF -- "$spec" "$chain"; then
                awk -v s="$spec" '!d && $0 == s { d = 1; next } 1' "$chain" >"$chain.new" && mv "$chain.new" "$chain"
            elif [ "$tolerant" = 0 ]; then
                return 1
            fi
            ;;
        *) return 1 ;;
        esac
    done <<<"$unit"
}
EB_WANT=$(run_sourced "$SANDBOX" tor_egress_rules 172.28.0.0/24 172.28.0.25 | sed 's/^/-m comment --comment pithead-tor-egress /')

echo "== boot: the unit's ExecStart lines rebuild the fail-closed chain on an empty DOCKER-USER =="
: >"$EB/chain"
eb_boot "$BU" "$EB/chain"
assert_rc "a fresh boot's start succeeds" "$?" "0"
assert_eq "a fresh boot leaves exactly the apply-time rules, in order, DROP last" "$(cat "$EB/chain")" "$EB_WANT"
eb_boot "$BU" "$EB/chain"
assert_eq "a manual restart replaces the rules instead of stacking duplicates" "$(cat "$EB/chain")" "$EB_WANT"
printf '%s\n' "-j RETURN" >"$EB/chain"
eb_boot "$BU" "$EB/chain"
assert_eq "a foreign DOCKER-USER rule survives, below ours" "$(cat "$EB/chain")" "$(printf '%s\n%s' "$EB_WANT" "-j RETURN")"
: >"$EB/chain"
FAIL_AT=3 eb_boot "$BU" "$EB/chain"
assert_rc "an insert failing halfway fails the unit" "$?" "1"
assert_contains "and the DROP is already live — a partial start over-blocks, never opens" "$(cat "$EB/chain")" \
    "-s 172.28.0.0/24 -j DROP"

echo "== provision: apply writes and enables the boot unit on a DIY Docker host (#2460) =="
rm -f "$EB_UNIT" "$EB/systemctl.log"
eb_run apply_tor_egress_firewall >/dev/null 2>&1
assert_eq "apply writes the unit the renderer produces" "$(cat "$EB_UNIT" 2>/dev/null)" \
    "$(run_sourced "$SANDBOX" render_tor_egress_boot_unit "$EB/bin/iptables" 172.28.0.0/24 172.28.0.25)"
assert_contains "apply enables it for the next boot" "$(cat "$EB/systemctl.log")" "enable pithead-egress.service"
assert_not_contains "apply does not start it (the live rules are apply's own; no double insert)" "$(cat "$EB/systemctl.log")" "--now"
assert_not_contains "and never starts or restarts it" "$(cat "$EB/systemctl.log")" "start pithead-egress"
rm -f "$EB/systemctl.log"
SYSTEMCTL_ENABLED=0 eb_run apply_tor_egress_firewall >/dev/null 2>&1
assert_not_contains "a re-apply with the same unit, already enabled, does not reload systemd" "$(cat "$EB/systemctl.log")" "daemon-reload"
printf 'NETWORK_SUBNET=172.29.0.0/24\nNETWORK_PREFIX=172.29.0\nTOR_EGRESS_FIREWALL=true\n' >"$EB/.env"
SYSTEMCTL_ENABLED=0 eb_run apply_tor_egress_firewall >/dev/null 2>&1
assert_contains "a changed subnet rewrites the unit" "$(cat "$EB_UNIT")" "-s 172.29.0.0/24 -j DROP"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$EB/.env"

rm -f "$EB_UNIT"
EB_APPLIANCE=1 eb_run apply_tor_egress_firewall >/dev/null 2>&1
assert_eq "the appliance gets no unit (pithead-boot owns its boot path)" "$([ -e "$EB_UNIT" ] && echo present)" ""
EB_ENGINE=podman eb_run apply_tor_egress_firewall >/dev/null 2>&1
assert_eq "a podman host gets no DOCKER-USER unit" "$([ -e "$EB_UNIT" ] && echo present)" ""

echo "== provision: opt-out and uninstall remove only the boot unit (#2460) =="
eb_run apply_tor_egress_firewall >/dev/null 2>&1
printf '[Unit]\n' >"$EB/units/other-firewall.service"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=false\n' >"$EB/.env"
rm -f "$EB/systemctl.log"
eb_run apply_tor_egress_firewall >/dev/null 2>&1
assert_eq "opting out removes the unit" "$([ -e "$EB_UNIT" ] && echo present)" ""
assert_contains "and disables it" "$(cat "$EB/systemctl.log")" "disable pithead-egress.service"
assert_eq "another service's unit is left alone" "$([ -e "$EB/units/other-firewall.service" ] && echo present)" "present"

printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$EB/.env"
eb_run apply_tor_egress_firewall >/dev/null 2>&1
un_out=$(
    cd "$EB" || exit
    export PITHEAD_ENGINE=docker PITHEAD_APPLIANCE=0 PITHEAD_UNIT_DIR="$EB/units" PATH="$EB/bin:$PATH"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    detect_os() { :; }
    docker() { :; }
    provision_control_runner() { :; }
    stack_uninstall -y 2>&1
)
assert_contains "uninstall completes" "$un_out" "Uninstalled."
assert_eq "uninstall removes the boot unit" "$([ -e "$EB_UNIT" ] && echo present)" ""
assert_eq "uninstall leaves another service's unit alone" "$([ -e "$EB/units/other-firewall.service" ] && echo present)" "present"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$EB/.env"

echo "== doctor: live rules without the boot unit are not reported as reboot-safe (#2460) =="
eb_doctor() {
    (
        cd "$EB" || exit
        export PITHEAD_ENGINE=docker PITHEAD_APPLIANCE=0 PITHEAD_UNIT_DIR="$EB/units" PATH="$EB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        container_is_running() { return 0; }
        tor_egress_enforced() { return 0; }
        check_egress_firewall_installed 2>&1
    )
}
dr=$(SYSTEMCTL_ENABLED=1 eb_doctor)
assert_contains "the live rules still read as installed" "$dr" "fail-closed via iptables"
assert_contains "a missing boot unit WARNs that a reboot drops the rules" "$dr" "will NOT survive a reboot"
assert_not_contains "no reboot WARN once the unit is enabled" "$(SYSTEMCTL_ENABLED=0 eb_doctor)" "will NOT survive a reboot"
