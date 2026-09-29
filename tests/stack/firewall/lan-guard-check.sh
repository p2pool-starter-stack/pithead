# shellcheck shell=bash
: "${STACK_SUITE:?source via tests/stack/run.sh}"
echo "== a periodic live-rule check closes a flushed LAN port (#2846) =="
mkdir -p "$LGD/units"
cat >"$LGD/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LG_SYSTEMCTL"
[ "$1" != is-active ]
SYSTEMCTL
chmod +x "$LGD/bin/systemctl"
printf '#!/usr/bin/env bash\necho Linux\n' >"$LGD/bin/uname"
chmod +x "$LGD/bin/uname"
export LG_SYSTEMCTL="$LGD/systemctl.log" PITHEAD_UNIT_DIR="$LGD/units" PITHEAD_APPLIANCE=0
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
lg provision_lan_guard_check_units >/dev/null
assert_eq "switch-off removes the timer" "$(test -e "$LGD/units/pithead-lan.timer" && echo present)" ""
lg_stale='docker() { case "$1" in ps) [ "$2" = -a ] && echo tari ;; port) echo 0.0.0.0:18142 ;; stop) echo tari >>"$LG_STOP" ;; esac; };'
lg "$lg_stale provision_lan_guard_check_units" >/dev/null
assert_eq "a stale stopped LAN publish keeps the timer after .env switches off" "$(test -e "$LGD/units/pithead-lan.timer" && echo present)" present
assert_eq "the check watches the stopped container's old port" "$(lg "$lg_stale lan_guard_watched_ports")" 18142
lg 'lan_guard_mark' >/dev/null
LG_LIVE=0 lg "$lg_stale mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; lan_guard_check" >/dev/null 2>&1 || true
assert_eq "a stale stopped node loses the marker before an explicit start" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
mv "$LGD/.env.lan" "$LGD/.env"
printf 'TARI_GRPC_BIND=0.0.0.0\n' >"$LGD/.env"
export LG_STOP="$LGD/stopped"
: >"$LG_STOP"
lg_check='mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; docker() { case "$1" in ps) printf "%s\n" monerod tari ;; port) echo 127.0.0.1:18081 ;; stop) printf "%s\n" "$2" >>"$LG_STOP" ;; esac; }; lan_guard_check'
LG_LIVE=1 lg 'lan_guard_mark; mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; lan_guard_check' >/dev/null
assert_eq "live rule leaves the marker" "$(cat "$LGD/data/lan-guard/enforced")" "boot-1"
lg_rc=0
LG_LIVE=0 lg "$lg_check" >/dev/null 2>&1 || lg_rc=$?
assert_eq "flushed rule makes the timer fail loudly" "$lg_rc" "1"
assert_eq "flushed rule invalidates the start marker" "$(test -e "$LGD/data/lan-guard/enforced" && echo present)" ""
assert_eq "only the LAN-publishing node is stopped" "$(cat "$LG_STOP")" "tari"
assert_contains "an explicit start after the check is refused" "$(
    PITHEAD_TEST_SOURCE=1 LAN_GUARD_MARKER="$LGD/data/lan-guard/enforced" BOOT_ID_FILE="$LGD/boot_id" bash -c 'source "$1"; lan_guard_gate 0.0.0.0; echo started' _ "$ROOT/build/tari/entrypoint.sh" 2>&1
    echo "rc=$?"
)" "rc=78"
printf 'MONERO_RPC_BIND=0.0.0.0\nMONERO_ZMQ_BIND=0.0.0.0\nTARI_GRPC_BIND=0.0.0.0\n' >"$LGD/.env"
: >"$LG_STOP"
LG_LIVE=0 lg "$lg_check" >/dev/null 2>&1 || true
assert_eq "both Monero ports stop monerod only once, and Tari separately" "$(tr '\n' ' ' <"$LG_STOP")" "monerod tari "
lg_rc=0
LG_LIVE=0 lg 'mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; lan_guard_unmark() { return 1; }; docker() { case "$1" in ps) echo tari ;; stop) return 1 ;; esac; }; lan_guard_check' >/dev/null 2>&1 || lg_rc=$?
assert_eq "marker or engine stop failure is a non-zero check" "$lg_rc" 1
: >"$LG_STOP"
lg_rc=0
LG_LIVE=0 lg 'mutation_lock_acquire() { :; }; mutation_lock_release() { :; }; docker() { case "$1" in ps) return 1 ;; stop) echo "$2" >>"$LG_STOP"; return 1 ;; esac; }; lan_guard_check' >/dev/null 2>&1 || lg_rc=$?
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
