# shellcheck shell=bash
: "${STACK_SUITE:?source via tests/stack/run.sh}"
echo "== a periodic live-rule check closes a flushed LAN port (#2846) =="
mkdir -p "$LGD/units"
cp "$LGD/bin/systemctl" "$LGD/systemctl.precheck"
cp "$LGD/.env" "$LGD/.env.precheck"
[ ! -e "$LGD/data/lan-guard/enforced" ] || cp "$LGD/data/lan-guard/enforced" "$LGD/marker.precheck"
lg 'lan_guard_mark' >/dev/null
if [ "$(uname -s)" = Linux ]; then
    cat /proc/sys/kernel/random/boot_id >"$LGD/data/lan-guard/enforced"
    assert_eq "a live proc boot ID matches its written marker" \
        "$(lg 'BOOT_ID_FILE=/proc/sys/kernel/random/boot_id; lan_guard_marker_current; echo $?')" 0
    lg 'lan_guard_mark' >/dev/null
fi
printf 'boot-1\n\n' >"$LGD/marker.bad"
printf '\n' >"$LGD/marker.blank"
: >"$LGD/boot.empty"
assert_eq "extra marker bytes never validate" "$(lg 'LAN_GUARD_MARKER=marker.bad; rc=0; lan_guard_marker_current || rc=$?; echo $rc')" 1
assert_eq "a missing boot ID never validates a newline-only marker" "$(lg 'BOOT_ID_FILE=missing; LAN_GUARD_MARKER=marker.blank; rc=0; lan_guard_marker_current || rc=$?; echo $rc')" 1
assert_eq "an unreadable boot ID never validates" "$(lg 'BOOT_ID_FILE=.; rc=0; lan_guard_marker_current || rc=$?; echo $rc')" 1
assert_eq "an empty boot ID never validates" "$(lg 'BOOT_ID_FILE=boot.empty; rc=0; lan_guard_marker_current || rc=$?; echo $rc')" 1
assert_eq "an empty marker never validates" "$(lg 'LAN_GUARD_MARKER=boot.empty; rc=0; lan_guard_marker_current || rc=$?; echo $rc')" 1
assert_eq "marker stays visible during an apply refresh" "$(lg 'mv() { test -e "$LAN_GUARD_MARKER" || return 1; command mv "$@"; }; lan_guard_mark; echo $?')" 0
assert_eq "node uid can read an atomically refreshed marker" "$(stat -c %a "$LGD/data/lan-guard/enforced" 2>/dev/null || stat -f %Lp "$LGD/data/lan-guard/enforced")" 644
cat >"$LGD/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LG_SYSTEMCTL"
[ "$1" != is-active ]
SYSTEMCTL
chmod +x "$LGD/bin/systemctl"
printf '#!/usr/bin/env bash\necho Linux\n' >"$LGD/bin/uname"
chmod +x "$LGD/bin/uname"
export LG_SYSTEMCTL="$LGD/systemctl.log"
printf 'TARI_GRPC_BIND=0.0.0.0\n' >"$LGD/.env"
lg_timer="$(run_sourced "$LGD" render_lan_guard_check_timer)"
assert_contains "timer checks within two minutes" "$lg_timer" "OnUnitActiveSec=2min"
assert_contains "timer is not coalesced by systemd's one-minute default" "$lg_timer" "AccuracySec=1s"
assert_contains "timer fires the check, not the boot restore" "$lg_timer" "Unit=pithead-lan-check.service"
lg_service="$(run_sourced "$LGD" render_lan_guard_check_service /opt/pithead docker)"
assert_contains "check runs the installed CLI" "$lg_service" "ExecStart=/opt/pithead/pithead lan-guard-check"
assert_contains "up provisions the timer" "$(run_sourced "$LGD" declare -f stack_up)" "provision_lan_guard_check_units"
assert_contains "uninstall removes the timer" "$(run_sourced "$LGD" declare -f stack_uninstall)" "remove_lan_guard_check_units"
lg provision_lan_guard_check_units >/dev/null
assert_contains "provision enables the timer" "$(cat "$LG_SYSTEMCTL")" "enable --now pithead-lan.timer"
assert_eq "provision writes the check unit" "$(test -e "$LGD/units/pithead-lan-check.service" && echo present)" present
cp "$LGD/.env" "$LGD/.env.lan"
printf 'TARI_GRPC_BIND=127.0.0.1\n' >"$LGD/.env"
LG_RUNNING=0 lg provision_lan_guard_check_units >/dev/null
assert_eq "switch-off removes the timer" "$(test -e "$LGD/units/pithead-lan.timer" && echo present)" ""
assert_eq "LAN repair still runs after a dashboard-only egress check failure" "$(lg 'provision_egress_check_units() { echo egress; return 1; }; provision_lan_guard_check_units() { echo lan; }; provision_firewall_check_units || echo failed')" $'egress\nlan'
assert_eq "LAN timer install failure propagates after egress repair" "$(lg 'provision_egress_check_units() { echo egress; }; provision_lan_guard_check_units() { echo lan; return 1; }; provision_firewall_check_units || echo failed')" $'egress\nlan\nfailed'
lg_stale='docker() { case "$1" in ps) [[ " $* " == *"service=tari"* ]] && echo tari; return 0 ;; port) echo 0.0.0.0:18142 ;; stop) echo tari >>"$LG_STOP" ;; esac; };'
lg "$lg_stale provision_lan_guard_check_units" >/dev/null
assert_eq "a stale stopped LAN publish keeps the timer after .env switches off" "$(test -e "$LGD/units/pithead-lan.timer" && echo present)" present
assert_eq "the check watches the stopped container's old port" "$(lg "$lg_stale lan_guard_watched_ports")" 18142
lg_prefixed='docker() { case "$1" in ps) [[ " $* " == *"service=tari"* ]] && echo 123456789abc_tari; return 0 ;; port) echo 0.0.0.0:18142 ;; stop) echo "$2" >>"$LG_STOP" ;; esac; };'
assert_eq "a Compose recreate name keeps the old port watched after switch-off" "$(lg "$lg_prefixed lan_guard_watched_ports")" 18142
printf 'MONERO_RPC_BIND=0.0.0.0\nTARI_GRPC_BIND=127.0.0.1\n' >"$LGD/.env.new"
assert_eq "transition protects the new bind and the old container publish" "$(lg "$lg_stale lan_guard_transition_ports '$LGD/.env.new'")" $'18142\n18081'
lg_apply="$(run_sourced "$LGD" declare -f apply)"
lg_prearm=missing
case "$lg_apply" in *'lan_guard_arm_transition "$newenv"'*'mv "$newenv" "$ENV_FILE"'*) lg_prearm=before-commit ;; esac
assert_eq "apply arms old and new ports before committing the new .env" "$lg_prearm" before-commit
lg_rc=0
lg_out=$(lg "docker() { case \"\$1\" in network) echo mining_net ;; esac; }; lan_guard_enforced() { return 4; }; provision_lan_guard_boot_unit() { :; }; lan_guard_arm_transition '$LGD/.env.new'" 2>&1) || lg_rc=$?
assert_eq "a missing FORWARD jump refuses the staged LAN bind" "$lg_rc" 1
assert_contains "a refused transition names the readback failure" "$lg_out" "nothing jumps from FORWARD to DOCKER-USER"
assert_eq "a refused transition leaves no node start marker" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
lg_rc=0
lg "docker() { case \"\$1\" in ps) echo stopped-node ;; esac; }; lan_guard_enforced() { return 4; }; provision_lan_guard_boot_unit() { :; }; lan_guard_arm_transition '$LGD/.env.new'" >/dev/null 2>&1 || lg_rc=$?
assert_eq "a stopped project node also forbids first-network staging" "$lg_rc" 1
assert_eq "the stopped-node refusal also invalidates the marker" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
lg_rc=0
lg "docker() { :; }; lan_guard_enforced() { return 4; }; provision_lan_guard_boot_unit() { :; }; lan_guard_arm_transition '$LGD/.env.new'" >/dev/null 2>&1 || lg_rc=$?
assert_eq "an absent first network can stage the guarded port" "$lg_rc" 0
lg 'lan_guard_unmark' >/dev/null
: >"$LG_RESTORE"
lg "$lg_stale lan_guard_enforced() { return 0; }; provision_lan_guard_boot_unit() { :; }; lan_guard_arm_transition '$LGD/.env.new'" >/dev/null
assert_contains "transition arms the new port" "$(cat "$LG_RESTORE")" "--dport 18081"
assert_contains "transition keeps the old port" "$(cat "$LG_RESTORE")" "--dport 18142"
printf 'MONERO_RPC_BIND=0.0.0.0\nTARI_GRPC_BIND=127.0.0.1\n' >"$LGD/.env"
assert_eq "timer accepts a newly enabled port before Compose convergence" "$(lg "$lg_stale lan_guard_enforced() { return 0; }; rc=0; lan_guard_check >/dev/null 2>&1 || rc=\$?; echo \$rc")" 0
: >"$LG_RESTORE"
lg "$lg_stale lan_guard_enforced() { return 0; }; provision_lan_guard_boot_unit() { :; }; apply_lan_guard" >/dev/null
assert_contains "apply guards the new configured port" "$(cat "$LG_RESTORE")" "--dport 18081"
assert_contains "apply keeps the old container port guarded until Compose converges" "$(cat "$LG_RESTORE")" "--dport 18142"
assert_eq "timer accepts the converging rule without stopping nodes" "$(lg "$lg_stale lan_guard_enforced() { [ \"\$*\" = \"18081 18142\" ]; }; rc=0; lan_guard_check >/dev/null 2>&1 || rc=\$?; echo \$rc")" 0
lg_interleaved='sudo() { case "$*" in *"-S PITHEAD-LAN"*) printf "%s\n" "-A PITHEAD-LAN -j DROP" ;; *"-S DOCKER-USER"*) printf "%s\n" "-A DOCKER-USER -p tcp --dport 18081 -m comment --comment pithead-lan-guard -j PITHEAD-LAN" "-A DOCKER-USER -j ACCEPT" "-A DOCKER-USER -p tcp --dport 18142 -m comment --comment pithead-lan-guard -j PITHEAD-LAN" ;; *"-S FORWARD"*) echo "-A FORWARD -j DOCKER-USER" ;; esac; };'
assert_eq "a foreign ACCEPT between two guard jumps shadows the second port" "$(lg "$lg_interleaved rc=0; lan_guard_enforced 18081 18142 || rc=\$?; echo \$rc")" 5
printf 'TARI_GRPC_BIND=127.0.0.1\n' >"$LGD/.env"
lg 'lan_guard_mark' >/dev/null
LG_LIVE=0 lg "$lg_stale mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; lan_guard_check" >/dev/null 2>&1 || true
assert_eq "a stale stopped node loses the marker before an explicit start" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
export LG_STOP="$LGD/stopped" LAN_GUARD_SETTLE=0
: >"$LG_STOP"
lg 'lan_guard_mark' >/dev/null
LG_LIVE=0 lg "$lg_prefixed mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; lan_guard_check" >/dev/null 2>&1 || true
assert_eq "a Compose recreate name is stopped after the rule is lost" "$(cat "$LG_STOP")" 123456789abc_tari
mv "$LGD/.env.lan" "$LGD/.env"
printf 'TARI_GRPC_BIND=0.0.0.0\n' >"$LGD/.env"
export LG_STOP="$LGD/stopped"
: >"$LG_STOP"
lg_check='mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; docker() { case "$1" in ps) case " $* " in *"service=monerod"*) echo monerod ;; *"service=tari"*) echo tari ;; esac ;; port) case "$2" in monerod) echo "${LG_MONERO_PORT:-127.0.0.1}:18081" ;; tari) echo "${LG_TARI_PORT:-0.0.0.0}:18142" ;; esac ;; stop) printf "%s\n" "$2" >>"$LG_STOP" ;; esac; }; lan_guard_check'
LG_LIVE=1 lg 'lan_guard_mark; mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; lan_guard_check' >/dev/null
assert_eq "live rule leaves the marker" "$(cat "$LGD/data/lan-guard/enforced")" "boot-1"
lg_rc=0
LG_LIVE=0 lg "$lg_check" >/dev/null 2>&1 || lg_rc=$?
assert_eq "flushed rule makes the timer fail loudly" "$lg_rc" "1"
assert_eq "flushed rule invalidates the start marker" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
assert_eq "only the LAN-publishing node is stopped" "$(cat "$LG_STOP")" "tari"
printf 'TARI_GRPC_BIND=0.0.0.0\n' >"$LGD/.env"
: >"$LG_STOP"
LG_LIVE=0 LG_TARI_PORT=127.0.0.1 lg "$lg_check" >/dev/null 2>&1 || true
assert_eq "a missing rule leaves a loopback-held LAN node running" "$(cat "$LG_STOP")" ""
exec 9>"$LGD/.pithead.lock"
flock -x 9
: >"$LG_STOP"
(
    exec 9>&-
    LG_LIVE=0 lg "$lg_check" >/dev/null 2>&1
) || true
flock -u 9
exec 9>&-
assert_eq "a real busy mutation lock does not delay the emergency stop" "$(cat "$LG_STOP")" tari
assert_contains "an explicit start after the check is refused" "$(
    PITHEAD_TEST_SOURCE=1 LAN_GUARD_MARKER="$LGD/data/lan-guard/enforced" BOOT_ID_FILE="$LGD/boot_id" bash -c 'source "$1"; lan_guard_gate 0.0.0.0; echo started' _ "$ROOT/build/tari/entrypoint.sh" 2>&1
    echo "rc=$?"
)" "rc=78"
printf 'MONERO_RPC_BIND=0.0.0.0\nMONERO_ZMQ_BIND=0.0.0.0\nTARI_GRPC_BIND=0.0.0.0\n' >"$LGD/.env"
: >"$LG_STOP"
LG_LIVE=0 LG_MONERO_PORT=0.0.0.0 lg "$lg_check" >/dev/null 2>&1 || true
assert_eq "both Monero ports stop monerod only once, and Tari separately" "$(tr '\n' ' ' <"$LG_STOP")" "monerod tari "
lg_rc=0
LG_LIVE=0 lg 'mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; lan_guard_unmark() { return 1; }; docker() { case "$1" in ps) echo tari ;; stop) return 1 ;; esac; }; lan_guard_check' >/dev/null 2>&1 || lg_rc=$?
assert_eq "marker or engine stop failure is a non-zero check" "$lg_rc" 1
: >"$LG_STOP"
lg_rc=0
LG_LIVE=0 lg 'mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; docker() { case "$1" in ps) return 1 ;; port) return 1 ;; stop) echo "$2" >>"$LG_STOP"; return 1 ;; esac; }; lan_guard_check' >/dev/null 2>&1 || lg_rc=$?
assert_eq "unreadable engine still attempts both known node stops" "$(tr '\n' ' ' <"$LG_STOP")" "monerod tari "
assert_eq "unreadable engine with no firewall cannot claim success" "$lg_rc" 1
printf 'TARI_GRPC_BIND=127.0.0.1\n' >"$LGD/.env"
: >"$LG_RESTORE"
lg_rc=0
LG_LIVE=0 lg 'flock() { return 1; }; docker() { case "$1" in ps) [ "$2" = -a ] && echo tari || echo tari ;; port) echo 0.0.0.0:18142 ;; stop) printf "MONERO_RPC_BIND=0.0.0.0\nTARI_GRPC_BIND=127.0.0.1\n" >.env; return 1 ;; esac; }; lan_guard_check' >/dev/null 2>&1 || lg_rc=$?
assert_eq "the check does not wait for a long mutation lock" "$lg_rc" 1
assert_contains "failed stop restores the stale published port even after .env switches off" "$(cat "$LG_RESTORE")" "--dport 18142"
assert_contains "emergency restore also protects a port enabled by concurrent up" "$(cat "$LG_RESTORE")" "--dport 18081"
assert_contains "emergency restore protects the other fixed Monero port" "$(cat "$LG_RESTORE")" "--dport 18083"
assert_eq "failed stop leaves the marker invalid for the next retry" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
printf 'TARI_GRPC_BIND=127.0.0.1\n' >"$LGD/.env"
: >"$LG_STOP"
lg_rc=0
LG_LIVE=0 lg 'flock() { return 1; }; lan_guard_enforced() { [ -e rule-restored ] && return 0; touch rule-restored; return 1; }; docker() { case "$1" in ps) [ "$2" = -a ] && echo tari || { touch rule-restored; lan_guard_mark; echo tari; } ;; port) echo 0.0.0.0:18142 ;; stop) echo "$2" >>"$LG_STOP" ;; esac; }; lan_guard_check' >/dev/null 2>&1 || lg_rc=$?
assert_eq "a concurrent up that restores the rule and marker is left running" "$(cat "$LG_STOP")" ""
assert_eq "a concurrent restore completes the check successfully" "$lg_rc" 0
rm -f "$LGD/rule-restored"
printf 'TARI_GRPC_BIND=0.0.0.0\n' >"$LGD/.env"
: >"$LG_STOP"
lg_rc=0
LG_LIVE=0 lg 'flock() { return 1; }; lan_guard_mark; n=0; lan_guard_enforced() { n=$((n + 1)); [ "$n" -gt 2 ]; }; docker() { case "$1" in ps) echo tari ;; port) echo 0.0.0.0:18142 ;; stop) echo "$2" >>"$LG_STOP" ;; esac; }; lan_guard_check' >/dev/null 2>&1 || lg_rc=$?
assert_eq "a tick that lands while up rewrites the rule stops nothing" "$(cat "$LG_STOP")" ""
assert_eq "a rule that settles during the busy-lock recheck is a passing check" "$lg_rc" 0
rm -f "$LGD/.env.new"
cp "$LGD/systemctl.precheck" "$LGD/bin/systemctl"
mv "$LGD/.env.precheck" "$LGD/.env"
rm -f "$LGD/units/pithead-lan.timer" "$LGD/units/pithead-lan-check.service" "$LGD/data/lan-guard/enforced"
[ ! -e "$LGD/marker.precheck" ] || mv "$LGD/marker.precheck" "$LGD/data/lan-guard/enforced"
unset LG_STOP
