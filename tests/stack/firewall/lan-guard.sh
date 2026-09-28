# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# LAN-only sources for the node ports the *_lan_access switches publish (#2616): the rule is rendered
# with the LAN set only, compose never publishes on 0.0.0.0 unless the rule is live (the loopback
# fallback), doctor tells exposed from held, and every publish of the three ports stays an explicit
# IPv4 bind, so the IPv4-only rule covers it, and the boot unit that restores the rule before
# docker.service starts, plus the hold that starts the LAN-access containers only after it (#2749). The live half, a non-private source refused on the
# bench before and after the rule is stripped and the unit re-run, is tests/integration/lib/run-lan-guard.sh.
# Sourced by tests/stack/run.sh.

LGD="$SANDBOX/lan-guard"
mkdir -p "$LGD/bin"
cat >"$LGD/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -n | -H | -E) shift ;; *) break ;; esac; done
exec "$@"
SUDO
# iptables: the chain and our jumps read back only when LG_LIVE=1, so "restore exited zero" and
# "the rule is live" can disagree.
cat >"$LGD/bin/iptables" <<'IPT'
#!/usr/bin/env bash
case "$*" in
"-S") exit 0 ;;
"-S PITHEAD-LAN")
    [ "${LG_LIVE:-0}" = 1 ] || exit 1
    printf '%s\n' '-N PITHEAD-LAN' '-A PITHEAD-LAN -s 10.0.0.0/8 -j RETURN' '-A PITHEAD-LAN -j DROP'
    ;;
"-S DOCKER-USER")
    echo '-N DOCKER-USER'
    [ -n "${LG_FOREIGN:-}" ] && echo "$LG_FOREIGN"
    [ "${LG_LIVE:-0}" = 1 ] && echo '-A DOCKER-USER -p tcp -m tcp --dport 18142 -m conntrack --ctstate NEW -m comment --comment "pithead-lan-guard" -j PITHEAD-LAN'
    exit 0
    ;;
"-S FORWARD") echo '-A FORWARD -j DOCKER-USER' ;;
esac
exit 0
IPT
cat >"$LGD/bin/iptables-restore" <<'IPR'
#!/usr/bin/env bash
cat >"$LG_RESTORE"
exit "${LG_RESTORE_RC:-0}"
IPR
cat >"$LGD/bin/nft" <<'NFT'
#!/usr/bin/env bash
case "$*" in
-f*) cat >"$LG_RESTORE" ;;
"list tables") exit 0 ;;
*"list table inet pithead_lan")
    [ "${LG_LIVE:-0}" = 1 ] || exit 1
    printf '%s\n' '{"nftables":[{"chain":{"name":"forward","hook":"forward"}},{"rule":{"chain":"forward","expr":[{"match":{"right":{"set":[18081,18142]}}},{"drop":null}]}}]}'
    ;;
esac
exit 0
NFT
# docker: `compose up` records the bind and the restart policies it was handed; `ps`/`port`/`inspect`
# answer the doctor rows (LG_RUNNING, LG_EXISTS, LG_POLICY, LG_EXIT).
cat >"$LGD/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1 ${2:-}" in
"compose up"*)
    echo "compose-bind=${TARI_GRPC_BIND:-from-env-file}" >>"$LG_COMPOSE"
    echo "restart=${MONERO_RESTART:-default},${TARI_RESTART:-default}" >>"$LG_COMPOSE.restart"
    ;;
"ps "*) [ "${LG_RUNNING:-1}" = 1 ] && echo cid123 ;;
"inspect -f")
    [ "${LG_EXISTS:-1}" = 1 ] || exit 1
    case "$3" in *RestartPolicy*) echo "${LG_POLICY:-no}" ;; *ExitCode*) echo "${LG_EXIT:-137}" ;; esac
    ;;
"port "*) echo "${LG_PUBLISHED:-0.0.0.0}:18142" ;;
esac
exit 0
DOCKER
printf '#!/usr/bin/env bash\necho Linux\n' >"$LGD/bin/uname" # OS_TYPE is read when pithead is sourced
# systemctl logs every call; `is-enabled` answers from LG_ENABLED (default: not enabled), `enable`
# from LG_ENABLE_RC, or LG_HOLD_ENABLE_RC for the hold unit (default: succeeds), `is-failed` from
# LG_GUARD_FAILED (default: not failed).
cat >"$LGD/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LG_SYSTEMCTL"
[ "$1" = is-enabled ] && exit "${LG_ENABLED:-1}"
[ "$1" = is-failed ] && exit "${LG_GUARD_FAILED:-1}"
[ "$1 ${2:-}" = "enable pithead-lan-hold.service" ] && exit "${LG_HOLD_ENABLE_RC:-0}"
[ "$1" = enable ] && exit "${LG_ENABLE_RC:-0}"
exit 0
SYSTEMCTL
chmod +x "$LGD/bin/"*
mkdir -p "$LGD/units"
export LG_RESTORE="$LGD/restore.in" LG_COMPOSE="$LGD/compose.log" LG_SYSTEMCTL="$LGD/systemctl.log"
printf 'TARI_GRPC_BIND=0.0.0.0\nMONERO_RPC_BIND=127.0.0.1\nMONERO_ZMQ_BIND=127.0.0.1\n' >"$LGD/.env"
printf 'boot-1\n' >"$LGD/boot_id"
lg() { (cd "$LGD" && PITHEAD_APPLIANCE="${LG_APPLIANCE:-0}" PITHEAD_UNIT_DIR="$LGD/units" PITHEAD_BOOT_ID_FILE="$LGD/boot_id" PATH="$LGD/bin:$PATH" bash -c "source '$STACK'; $1" 2>&1); }
LG_UNIT="$LGD/units/pithead-lan-guard.service"
LG_HOLD="$LGD/units/pithead-lan-hold.service"

echo "== the rule admits loopback, RFC1918 and CGNAT only, and drops the rest (#2616) =="
lg_out="$(printf '%s\n' '-A DOCKER-USER -p tcp -m tcp --dport 18081 -m comment --comment pithead-lan-guard -j PITHEAD-LAN' |
    run_sourced "$LGD" render_lan_guard_iptables 18142)"
assert_eq "iptables: the chain RETURNs exactly the LAN set, then DROPs" \
    "$(grep -- '-A PITHEAD-LAN' <<<"$lg_out" | tr '\n' '|')" \
    "-A PITHEAD-LAN -s 127.0.0.0/8 -j RETURN|-A PITHEAD-LAN -s 10.0.0.0/8 -j RETURN|-A PITHEAD-LAN -s 172.16.0.0/12 -j RETURN|-A PITHEAD-LAN -s 192.168.0.0/16 -j RETURN|-A PITHEAD-LAN -s 100.64.0.0/10 -j RETURN|-A PITHEAD-LAN -j DROP|"
assert_contains "iptables: a NEW connection to the published port jumps to the chain" "$lg_out" \
    "-I DOCKER-USER 1 -p tcp -m tcp --dport 18142 -m conntrack --ctstate NEW -m comment --comment pithead-lan-guard -j PITHEAD-LAN"
assert_contains "iptables: a port no longer published loses its jump in the same commit" "$lg_out" "-D DOCKER-USER -p tcp -m tcp --dport 18081"
assert_eq "iptables: one commit, so no packet sees a half-built set" "$(tail -n 1 <<<"$lg_out")" "COMMIT"
lg_out="$(run_sourced "$LGD" render_lan_guard_nft 18081 18142)"
assert_contains "nft: drop NEW connections to the ports from outside the LAN set" "$lg_out" \
    "tcp dport { 18081, 18142 } ct state new ip saddr != { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10 } drop"
assert_contains "nft: its own table, hooked at forward" "$lg_out" "type filter hook forward priority -5"

echo "== compose never publishes on 0.0.0.0 unless the rule is live (#2616) =="
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=1 lg 'compose_up -d')"
assert_contains "installed and read back: apply says so" "$lg_out" "LAN-only sources enforced on port(s) 18142"
assert_contains "installed: only the published port gets a jump" "$(cat "$LG_RESTORE")" "--dport 18142"
assert_not_contains "installed: a loopback-bound port gets none" "$(cat "$LG_RESTORE")" "--dport 18081"
assert_eq "installed: compose publishes the .env bind" "$(cat "$LG_COMPOSE")" "compose-bind=from-env-file"
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=0 lg 'compose_up -d')"
assert_contains "restore exits 0 but the rule is not live: named" "$lg_out" "lan-guard:not-installed"
assert_eq "...and compose is handed 127.0.0.1, not 0.0.0.0" "$(cat "$LG_COMPOSE")" "compose-bind=127.0.0.1"
: >"$LG_COMPOSE"
lg_out="$(LG_LIVE=1 LG_RESTORE_RC=1 lg 'compose_up -d')"
assert_contains "the install itself fails (no root): the reason is named" "$lg_out" "could not enforce"
assert_eq "...and compose is handed 127.0.0.1" "$(cat "$LG_COMPOSE")" "compose-bind=127.0.0.1"
: >"$LG_COMPOSE"
rm -f "$LG_UNIT"
lg_out="$(LG_LIVE=1 LG_ENABLE_RC=1 lg 'compose_up -d')"
assert_contains "the rule is live but its boot unit cannot be enabled: named (#2749)" "$lg_out" "boot unit that restores it after a reboot could not be installed"
assert_eq "...and compose is handed 127.0.0.1, so a reboot cannot reopen the port" "$(cat "$LG_COMPOSE")" "compose-bind=127.0.0.1"
: >"$LG_COMPOSE"
lg_out="$(PITHEAD_ENGINE=podman LG_LIVE=0 lg 'compose_up -d')"
assert_eq "podman: an nft table that does not read back holds the port on 127.0.0.1" "$(cat "$LG_COMPOSE")" "compose-bind=127.0.0.1"
lg_out="$(PITHEAD_ENGINE=podman LG_LIVE=1 lg 'apply_lan_guard')"
assert_contains "podman: a table with the drop and the port is enforced" "$lg_out" "LAN-only sources enforced"
rm -f "$LG_RESTORE"
cp "$LGD/.env" "$LGD/.env.on"
printf 'TARI_GRPC_BIND=127.0.0.1\n' >"$LGD/.env"
lg_out="$(lg apply_lan_guard)"
mv "$LGD/.env.on" "$LGD/.env"
assert_eq "every switch off: nothing is installed and nothing is said" "$lg_out" ""
assert_eq "...and no firewall command runs" "$(test -e "$LG_RESTORE" && echo ran || echo none)" "none"

echo "== the rule survives a DIY host reboot: pithead-lan-guard.service, ahead of docker (#2749) =="
lg_bu="$(run_sourced "$LGD" render_lan_guard_boot_unit /usr/sbin/iptables /srv/pithead/data/lan-guard/enforced 18081 18142)"
assert_eq "last, once every rule is in, it records the current boot id as the nodes' marker (#2749)" \
    "$(tail -n 5 <<<"$lg_bu" | grep '^ExecStartPost=')" \
    'ExecStartPost=/bin/sh -c "rm -f /srv/pithead/data/lan-guard/enforced && cat /proc/sys/kernel/random/boot_id > /srv/pithead/data/lan-guard/enforced"'
assert_contains "runs before docker.service restarts the containers" "$lg_bu" "Before=docker.service"
assert_contains "every docker start pulls it in (boot and socket activation)" "$lg_bu" "WantedBy=docker.service"
assert_contains "a oneshot that stays active" "$lg_bu" "RemainAfterExit=yes"
assert_contains "runs after the host firewall loaders and the egress unit, so its jumps land on top as after up" "$lg_bu" \
    "After=ufw.service firewalld.service netfilter-persistent.service nftables.service pithead-egress.service"
assert_eq "an insert failure fails the unit (no '-' prefix on any insert or append)" \
    "$(grep -cE '^ExecStart=-.* -[IA] ' <<<"$lg_bu")" "0"
assert_eq "every ExecStart runs iptables and nothing else (no checkout path, no docker call)" \
    "$(grep '^ExecStart=' <<<"$lg_bu" | grep -vc '^ExecStart=-\{0,1\}/usr/sbin/iptables ')" "0"
# The chain edits in unit order: the DROP is live before any jump reaches the chain, so a start that
# stops halfway over-blocks, and the finished chain matches what apply installs.
lg_first="$(grep -nE ' -A PITHEAD-LAN | -I PITHEAD-LAN | -I DOCKER-USER ' <<<"$lg_bu" | head -n 1)"
assert_contains "the chain's DROP is the first rule the unit puts in" "$lg_first" " -A PITHEAD-LAN -j DROP"
assert_eq "the jumps come last, after every RETURN" \
    "$(grep -E ' -I (PITHEAD-LAN|DOCKER-USER) ' <<<"$lg_bu" | awk '{print $3}' | uniq | tr '\n' ' ')" "PITHEAD-LAN DOCKER-USER "
lg_chain=""
while read -r lg_s; do lg_chain="-A PITHEAD-LAN -s $lg_s -j RETURN|$lg_chain"; done \
    < <(grep ' -I PITHEAD-LAN 1 ' <<<"$lg_bu" | awk '{print $6}')
assert_eq "the restored chain is apply's: the LAN set RETURNed in order, then DROP" "$lg_chain-A PITHEAD-LAN -j DROP|" \
    "$(run_sourced "$LGD" render_lan_guard_iptables 18142 </dev/null | grep -- '-A PITHEAD-LAN' | tr '\n' '|')"
for p in 18081 18142; do
    assert_contains "port $p gets apply's own jump" "$lg_bu" \
        "ExecStart=/usr/sbin/iptables -I DOCKER-USER 1 -p tcp -m tcp --dport $p -m conntrack --ctstate NEW -m comment --comment pithead-lan-guard -j PITHEAD-LAN"
    assert_contains "port $p's old jump is deleted first, so a restart does not stack them" "$lg_bu" \
        "ExecStart=-/usr/sbin/iptables -D DOCKER-USER -p tcp -m tcp --dport $p "
done

lg_hu="$(run_sourced "$LGD" render_lan_guard_hold_unit /usr/bin/docker /usr/sbin/iptables 18081 18083 18142)"
assert_contains "the hold needs the guard: a failed guard never starts the containers" "$lg_hu" \
    "Requires=pithead-lan-guard.service docker.service"
assert_contains "...and runs after both" "$lg_hu" "After=pithead-lan-guard.service docker.service"
assert_contains "the hold is pulled in by the boot, not by docker.service" "$lg_hu" "WantedBy=multi-user.target"
assert_not_contains "docker.service never depends on the hold" "$lg_hu" "WantedBy=docker.service"
assert_eq "it starts each publishing container once, a removed one no failure" \
    "$(grep '^ExecStart=' <<<"$lg_hu" | tr '\n' '|')" "ExecStart=-/usr/bin/docker start monerod|ExecStart=-/usr/bin/docker start tari|"
assert_contains "...and the chain's live DROP, so a flushed chain behind a live jump fails it too" "$lg_hu" \
    "ExecStartPre=/usr/sbin/iptables -C PITHEAD-LAN -j DROP"
assert_eq "...only after checking each port's live jump, which fails the start when it is gone" \
    "$(grep -c '^ExecStartPre=/usr/sbin/iptables -C DOCKER-USER -p tcp -m tcp --dport 18[01][0-9]* -m conntrack --ctstate NEW -m comment --comment pithead-lan-guard -j PITHEAD-LAN$' <<<"$lg_hu")" "3"

rm -f "$LG_UNIT" "$LG_SYSTEMCTL" "$LG_HOLD"
: >"$LG_COMPOSE.restart"
LG_LIVE=1 lg 'compose_up -d' >/dev/null
assert_eq "a live apply hands compose restart no for the container publishing a LAN port, and only it" \
    "$(cat "$LG_COMPOSE.restart")" "restart=unless-stopped,no"
assert_eq "...and writes the hold for that container" "$(cat "$LG_HOLD" 2>/dev/null)" \
    "$(run_sourced "$LGD" render_lan_guard_hold_unit "$LGD/bin/docker" "$LGD/bin/iptables" 18142)"
assert_contains "...enabled for the next boot" "$(cat "$LG_SYSTEMCTL")" "enable pithead-lan-hold.service"
rm -f "$LG_HOLD"
: >"$LG_COMPOSE"
: >"$LG_COMPOSE.restart"
lg_out="$(LG_LIVE=1 LG_HOLD_ENABLE_RC=1 lg 'compose_up -d')"
assert_contains "the hold cannot be enabled: named" "$lg_out" "boot unit that restores it after a reboot could not be installed"
assert_eq "...compose is handed 127.0.0.1" "$(cat "$LG_COMPOSE")" "compose-bind=127.0.0.1"
assert_eq "...and the default restart, harmless on loopback" "$(cat "$LG_COMPOSE.restart")" "restart=unless-stopped,unless-stopped"
for lg_case in "LG_LIVE=0" "LG_LIVE=1 LG_APPLIANCE=1" "LG_LIVE=1 PITHEAD_ENGINE=podman"; do
    : >"$LG_COMPOSE.restart"
    # shellcheck disable=SC2086,SC2163 # the case is a list of NAME=value words
    (export $lg_case && lg 'compose_up -d' >/dev/null)
    assert_eq "$lg_case: compose keeps the default restart" "$(cat "$LG_COMPOSE.restart")" "restart=unless-stopped,unless-stopped"
done

rm -f "$LG_UNIT" "$LG_SYSTEMCTL"
LG_LIVE=1 lg apply_lan_guard >/dev/null
assert_eq "a live apply writes the unit for the published ports" "$(cat "$LG_UNIT" 2>/dev/null)" \
    "$(lg 'render_lan_guard_boot_unit "$(command -v iptables)" "$PWD/data/lan-guard/enforced" 18142')"
assert_contains "...and enables it for the next boot" "$(cat "$LG_SYSTEMCTL")" "enable pithead-lan-guard.service"
assert_not_contains "...without starting it (apply's rule is already live)" "$(cat "$LG_SYSTEMCTL")" "start pithead-lan-guard"
rm -f "$LG_SYSTEMCTL"
LG_LIVE=1 LG_ENABLED=0 lg apply_lan_guard >/dev/null
assert_not_contains "a re-apply with the same unit, already enabled, does not reload systemd" "$(cat "$LG_SYSTEMCTL" 2>/dev/null)" "daemon-reload"
rm -f "$LG_UNIT"
LG_LIVE=0 lg apply_lan_guard >/dev/null
assert_eq "a port held on loopback gets no unit" "$(test -e "$LG_UNIT" && echo present)" ""
LG_LIVE=1 LG_APPLIANCE=1 lg apply_lan_guard >/dev/null
assert_eq "the appliance gets no unit (pithead-boot runs up, which installs the rule first)" "$(test -e "$LG_UNIT" && echo present)" ""
PITHEAD_ENGINE=podman LG_LIVE=1 lg apply_lan_guard >/dev/null
assert_eq "a podman host gets no DOCKER-USER unit" "$(test -e "$LG_UNIT" && echo present)" ""
LG_LIVE=1 lg apply_lan_guard >/dev/null
printf '[Unit]\n' >"$LGD/units/other-firewall.service"
cp "$LGD/.env" "$LGD/.env.on"
printf 'TARI_GRPC_BIND=127.0.0.1\n' >"$LGD/.env"
rm -f "$LG_SYSTEMCTL"
lg apply_lan_guard >/dev/null
mv "$LGD/.env.on" "$LGD/.env"
assert_eq "every switch off removes the unit" "$(test -e "$LG_UNIT" && echo present)" ""
assert_eq "...and the hold" "$(test -e "$LG_HOLD" && echo present)" ""
assert_contains "...and disables it" "$(cat "$LG_SYSTEMCTL")" "disable pithead-lan-guard.service"
assert_eq "...leaving another service's unit alone" "$(test -e "$LGD/units/other-firewall.service" && echo present)" "present"
LG_LIVE=1 lg apply_lan_guard >/dev/null
cp "$LGD/.env" "$LGD/.env.keep"
lg_out="$(lg 'set +e; detect_os() { :; }; docker() { :; }; provision_control_runner() { :; }; stack_uninstall -y')"
assert_contains "uninstall completes" "$lg_out" "Uninstalled."
assert_eq "uninstall removes the unit" "$(test -e "$LG_UNIT" && echo present)" ""
assert_eq "...and the hold" "$(test -e "$LG_HOLD" && echo present)" ""
mv "$LGD/.env.keep" "$LGD/.env" # uninstall removes .env too

echo "== doctor tells a port held on loopback from one exposed without the rule (#2616) =="
lg_out="$(LG_LIVE=1 LG_ENABLED=0 lg check_lan_guard)"
assert_contains "rule live and its boot unit enabled: OK" "$lg_out" "LAN-only sources enforced on port(s) 18142"
lg_out="$(LG_LIVE=1 LG_ENABLED=1 lg check_lan_guard)"
assert_contains "rule live but no boot unit enabled: WARN that a reboot reopens it (#2749)" "$lg_out" "a reboot reopens them"
assert_not_contains "...and never OK" "$lg_out" "LAN-only sources enforced on port(s) 18142:"
lg_out="$(LG_LIVE=1 LG_ENABLED=1 LG_APPLIANCE=1 lg check_lan_guard)"
assert_contains "the appliance needs no boot unit: OK" "$lg_out" "LAN-only sources enforced on port(s) 18142"
lg_out="$(LG_LIVE=0 LG_PUBLISHED=0.0.0.0 lg check_lan_guard)"
assert_contains "rule missing and the port on 0.0.0.0: FAIL" "$lg_out" "published on every interface with NO LAN-only source rule"
lg_out="$(LG_LIVE=0 LG_PUBLISHED=127.0.0.1 lg check_lan_guard)"
assert_contains "rule missing and the port on loopback: says it is held, and why" "$lg_out" "held on 127.0.0.1"
assert_contains "...naming the reason" "$lg_out" "not in the live ruleset"
lg_out="$(LG_LIVE=1 LG_FOREIGN='-A DOCKER-USER -j ACCEPT' LG_PUBLISHED=0.0.0.0 lg check_lan_guard)"
assert_contains "a foreign ACCEPT above our jumps is not called enforced" "$lg_out" "not ours accepts traffic above it"

echo "== doctor names a held or exited LAN-access node, and a restart policy that would beat the rule (#2749) =="
lg_out="$(LG_LIVE=1 LG_ENABLED=0 LG_RUNNING=0 LG_GUARD_FAILED=0 lg check_lan_guard)"
assert_contains "guard failed at boot: tari is down, held, with the recovery" "$lg_out" \
    "tari is down: held since boot, because pithead-lan-guard.service failed"
assert_contains "...and the recovery" "$lg_out" "Run './pithead up' to start it."
lg_out="$(LG_LIVE=1 LG_ENABLED=0 LG_RUNNING=0 LG_EXIT=139 lg check_lan_guard)"
assert_contains "exited while running: named, with its exit code" "$lg_out" \
    "tari is down: it exited (code 139), and with LAN access on Docker does not restart it"
lg_out="$(LG_LIVE=1 LG_ENABLED=0 LG_RUNNING=0 LG_EXISTS=0 lg check_lan_guard)"
assert_not_contains "a container down removed is no verdict" "$lg_out" "is down:"
lg_out="$(LG_LIVE=1 LG_ENABLED=0 LG_POLICY=unless-stopped lg check_lan_guard)"
assert_contains "running with a restart Docker acts on at boot: FAIL" "$lg_out" "restart policy 'unless-stopped'"
lg_out="$(LG_LIVE=1 LG_ENABLED=0 lg check_lan_guard)"
assert_not_contains "running with restart no: no hold verdict" "$lg_out" "restart policy"
lg_out="$(LG_LIVE=1 LG_APPLIANCE=1 LG_RUNNING=0 LG_GUARD_FAILED=0 lg check_lan_guard)"
assert_not_contains "the appliance has no hold to report" "$lg_out" "is down:"

echo "== only the two LAN-access node services take their restart policy from apply_lan_guard (#2749) =="
# shellcheck disable=SC2016 # the compose text itself, unexpanded
assert_eq "monerod and tari take MONERO_RESTART/TARI_RESTART, and a compose run without them fails closed to no" \
    "$(grep -E '^    restart: \$\{' "$ROOT/docker-compose.yml" | tr '\n' '|')" \
    '    restart: ${MONERO_RESTART:-no}|    restart: ${TARI_RESTART:-no}|'
assert_eq "...in that order: monerod's first, tari's second" \
    "$(awk '/^  [a-z-]+:$/{svc=$1} /^    restart: \$\{/{print svc}' "$ROOT/docker-compose.yml" | tr '\n' ' ')" "monerod: tari: "

echo "== the marker the node entrypoints check follows the live rule (#2749) =="
rm -f "$LGD/data/lan-guard/enforced"
LG_LIVE=1 lg apply_lan_guard >/dev/null
assert_eq "a live apply records this boot's id" "$(cat "$LGD/data/lan-guard/enforced" 2>/dev/null)" "boot-1"
LG_LIVE=0 lg apply_lan_guard >/dev/null
assert_eq "an apply that holds the port on loopback clears it" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
LG_LIVE=1 lg apply_lan_guard >/dev/null
lg remove_lan_guard >/dev/null
assert_eq "removing the rule (down, the backup window) clears it" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""

echo "== the node entrypoints refuse a LAN bind without a current marker, however started (#2749) =="
printf 'boot-1\n' >"$LGD/marker"
lg_gate() { # <marker content or -> <bind>...  (entrypoint in $lg_ep)
    local m="$1"
    shift
    [ "$m" = - ] && rm -f "$LGD/marker" || printf '%s\n' "$m" >"$LGD/marker"
    (
        PITHEAD_TEST_SOURCE=1 LAN_GUARD_MARKER="$LGD/marker" BOOT_ID_FILE="$LGD/boot_id" bash -c \
            'source "$1"; shift; lan_guard_gate "$@"; echo started' _ "$ROOT/$lg_ep" "$@" 2>&1
        echo "rc=$?"
    )
}
for lg_ep in build/monero/entrypoint.sh build/tari/entrypoint.sh; do
    assert_contains "$lg_ep: a loopback bind starts without a marker" "$(lg_gate - 127.0.0.1)" "started"
    assert_contains "$lg_ep: a LAN bind with no marker exits 78 before the daemon" "$(lg_gate - 0.0.0.0)" "rc=78"
    assert_not_contains "...and never reaches it" "$(lg_gate - 0.0.0.0)" "started"
    assert_contains "$lg_ep: a marker from an earlier boot is refused too" "$(lg_gate boot-0 127.0.0.1 0.0.0.0)" "rc=78"
    assert_contains "$lg_ep: this boot's marker lets a LAN bind start" "$(lg_gate boot-1 0.0.0.0)" "started"
    assert_contains "$lg_ep: an unreadable boot id never matches a missing marker" \
        "$(
            mv "$LGD/boot_id" "$LGD/boot_id.off" && lg_gate - 0.0.0.0
            mv "$LGD/boot_id.off" "$LGD/boot_id"
        )" "rc=78"
    assert_eq "$lg_ep: the gate runs before the daemon starts" \
        "$(grep -nE '^lan_guard_gate |^exec monerod|^run_node ' "$ROOT/$lg_ep" | head -n 1 | cut -d: -f2 | cut -c1-14)" "lan_guard_gate"
done
assert_eq "compose hands each node its binds and the marker dir, read-only" \
    "$(grep -cE '^      - (MONERO_RPC_BIND=\$\{MONERO_RPC_BIND:-127\.0\.0\.1\}|MONERO_ZMQ_BIND=\$\{MONERO_ZMQ_BIND:-127\.0\.0\.1\}|TARI_GRPC_BIND=\$\{TARI_GRPC_BIND:-127\.0\.0\.1\}|\./data/lan-guard:/lan-guard:ro)$' "$ROOT/docker-compose.yml")" "5"

echo "== down and the backup window remove the rule only after the nodes stopped (#2749) =="
for lg_fn in stack_down stack_down_except_caddy stack_uninstall; do
    lg_body="$(run_sourced "$LGD" declare -f "$lg_fn")"
    assert_eq "$lg_fn: the node stop comes before remove_lan_guard" \
        "$(grep -nE 'docker compose (down|stop)|remove_lan_guard' <<<"$lg_body" | head -n 2 | grep -c 'docker compose')" "1"
done
lg_out="$(LG_LIVE=1 lg 'lan_guard_mark; mutation_lock_acquire() { :; }; docker() { [ "$2" = down ] && return 1; :; }; stack_down' 2>&1)"
assert_eq "a down whose stop fails leaves the marker (the nodes may still run)" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" "present"

echo "== a restart, which bypasses compose_up, needs the live rule first (#2749) =="
lg_rc=0
LG_LIVE=0 lg lan_guard_ready >/dev/null || lg_rc=$?
assert_eq "a published port without its live rule is not ready" "$([ "$lg_rc" != 0 ] && echo refused)" "refused"
lg_rc=0
LG_LIVE=1 lg lan_guard_ready >/dev/null || lg_rc=$?
assert_eq "...with it, ready" "$lg_rc" "0"
# The reported interleaving: a `down` or backup holds the lock and removes the rule while restart
# waits for it. The check has to see the state after the lock, not before.
lg_out="$(LG_LIVE=1 lg 'mutation_lock_acquire() { export LG_LIVE=0; }; docker() { echo "ran: docker $*"; }; stack_restart monerod')"
assert_contains "restart refuses when the rule went away while it waited for the lock" "$lg_out" "not in place"
assert_not_contains "...and restarts nothing" "$lg_out" "ran: docker compose restart"
lg_out="$(LG_LIVE=1 lg 'mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; docker() { echo "ran: docker $*"; }; stack_restart monerod')"
assert_contains "with the rule still live after the lock, it restarts" "$lg_out" "ran: docker compose restart monerod"

echo "== every publish of 18081, 18083 and 18142 is an explicit IPv4 bind (#2616) =="
# The rule is IPv4 only. `[::]:P:P` or a bare `P:P` would also listen on IPv6, where nothing limits
# the source, so a change of either shape, or of an engine default behind one, has to fail here.
for kp in MONERO_RPC_BIND:18081 MONERO_ZMQ_BIND:18083 TARI_GRPC_BIND:18142; do
    k="${kp%%:*}" p="${kp#*:}"
    assert_eq "compose publishes $p only as \${$k:-127.0.0.1}" \
        "$(grep -E "^ *- *\"?[^ \"=]*\b$p(:$p)?(/tcp)?\"? *$" "$ROOT/docker-compose.yml" | sed 's/^ *//' | tr '\n' '|')" \
        "- \"\${$k:-127.0.0.1}:$p:$p\"|"
    assert_eq "quadlet publishes $p only from $k" \
        "$(grep -E "PublishPort=.*:$p(:|$)" "$ROOT/lib/pithead/36-quadlet-units.sh" | tr '\n' '|')" \
        "PublishPort=\$(_qenv $k):$p:$p|"
done
assert_eq "render_env assigns the three binds only IPv4 literals" \
    "$(grep -E '(rpc|zmq|tari_grpc)_bind="' "$ROOT/lib/pithead/33-render-env.sh" | grep -oE '_bind="[^"]*"' | sort -u | tr '\n' '|')" \
    '_bind="0.0.0.0"|_bind="127.0.0.1"|'
