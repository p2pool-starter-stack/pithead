# shellcheck shell=bash
# Sourced by lan-guard.sh with its stub engine and assertion helpers.
: >"$LG_ORDER"
lg 'apply_lan_guard() { echo lan >>"$LG_ORDER"; }; apply_tor_egress_firewall() { echo "egress:$1" >>"$LG_ORDER"; }; compose_up -d' >/dev/null
assert_eq "compose restores egress precedence after LAN jumps, before containers start" \
    "$(cat "$LG_ORDER")" $'lan\negress:refresh\ncompose'
: >"$LG_ORDER"
lg_out="$(lg 'apply_lan_guard() { echo lan >>"$LG_ORDER"; }; apply_tor_egress_firewall() { echo "egress:$1" >>"$LG_ORDER"; return 1; }; clearnet_sync_active() { return 0; }; if compose_up -d; then echo rc=0; else echo "rc=$?"; fi')"
assert_eq "failed egress refresh prevents container startup" "$(cat "$LG_ORDER")" $'lan\negress:refresh'
assert_contains "failed refresh returns failure" "$lg_out" "rc=1"
echo "== a switch-off stops the old LAN listener before its jump is removed (#2902) =="
LG_RUNNING_FILE="$LGD/running-nodes"
export LG_RUNNING_FILE
printf 'monerod\ntari\n' >"$LG_RUNNING_FILE"
: >"$LG_ORDER"
: >"$LG_COMPOSE"
LG_LIVE=1 LG_OLD_MONERO_RPC=0.0.0.0 LG_COMPOSE_RC=1 lg 'compose_up -d' >/dev/null
lg_rc=$?
assert_eq "a Compose failure is returned" "$lg_rc" "1"
assert_eq "the old Monero publisher is stopped before rules change; Tari stays running" \
    "$(cat "$LG_RUNNING_FILE")" "tari"
assert_eq "the old rule is refreshed before the listener stops and Compose fails" \
    "$(cat "$LG_ORDER")" $'restore\nstop:monerod\ncompose'
: >"$LG_ORDER"
printf 'monerod\ntari\n' >"$LG_RUNNING_FILE"
LG_LIVE=1 LG_OLD_MONERO_RPC=0.0.0.0 LG_STOP_FAIL=1 lg 'compose_up -d' >/dev/null
lg_rc=$?
assert_eq "a failed stop refuses startup" "$lg_rc" "1"
assert_eq "a failed stop first restores the old rule" "$(head -n 1 "$LG_ORDER")" restore
assert_not_contains "a failed stop never invokes Compose" "$(cat "$LG_ORDER")" compose
: >"$LG_ORDER"
printf 'monerod\ntari\n' >"$LG_RUNNING_FILE"
LG_LIVE=0 LG_OLD_MONERO_RPC=0.0.0.0 LG_STOP_FAIL=1 lg 'compose_up -d' >/dev/null
lg_rc=$?
assert_eq "a lost rule and failed stop refuse startup" "$lg_rc" 1
assert_eq "a lost rule gets an emergency restore before the failed stop" "$(head -n 1 "$LG_ORDER")" restore
assert_not_contains "a lost rule and failed stop never invoke Compose" "$(cat "$LG_ORDER")" compose
: >"$LG_ORDER"
printf 'monerod\ntari\n' >"$LG_RUNNING_FILE"
printf 'MONERO_RPC_BIND=0.0.0.0\nMONERO_ZMQ_BIND=127.0.0.1\nTARI_GRPC_BIND=0.0.0.0\n' >"$LGD/.env.lan-fallback"
cp "$LGD/.env" "$LGD/.env.fallback-original"
cp "$LGD/.env.lan-fallback" "$LGD/.env"
LG_LIVE=0 LG_OLD_MONERO_RPC=0.0.0.0 LG_COMPOSE_RC=1 lg 'compose_up -d' >/dev/null
assert_eq "a failed rule stops old LAN listeners despite loopback fallback only in Compose's environment" \
    "$(cat "$LG_RUNNING_FILE")" ""
assert_eq "a failed rule stops old listeners before Compose and its loopback recovery fail" \
    "$(cat "$LG_ORDER")" $'restore\nstop:monerod\nstop:tari\ncompose\ncompose'
mv "$LGD/.env.fallback-original" "$LGD/.env"
: >"$LG_ORDER"
printf 'monerod\ntari\n' >"$LG_RUNNING_FILE"
LG_LIVE=1 LG_OLD_MONERO_RPC=$'127.0.0.1:18081\n0.0.0.0' LG_COMPOSE_RC=1 lg 'compose_up -d' >/dev/null
assert_eq "a second all-interface binding is not hidden by a loopback binding" \
    "$(cat "$LG_RUNNING_FILE")" "tari"
: >"$LG_ORDER"
printf '123456789abc_monerod\ntari\n' >"$LG_RUNNING_FILE"
LG_LIVE=1 LG_OLD_MONERO_RPC=0.0.0.0 LG_COMPOSE_RC=1 lg 'compose_up -d' >/dev/null
assert_eq "an interrupted Compose replacement is stopped by its service label" \
    "$(cat "$LG_RUNNING_FILE")" "tari"
assert_eq "the replacement is stopped before its old jump is removed" \
    "$(cat "$LG_ORDER")" $'restore\nstop:123456789abc_monerod\ncompose'
: >"$LG_ORDER"
: >"$LG_RUNNING_FILE"
LG_FOREIGN_FILE="$LGD/foreign-nodes"
export LG_FOREIGN_FILE
printf 'monerod\n' >"$LG_FOREIGN_FILE"
LG_LIVE=1 LG_OLD_MONERO_RPC=0.0.0.0 LG_COMPOSE_RC=1 lg 'compose_up -d' >/dev/null
assert_eq "a same-named container from another project stays running" \
    "$(cat "$LG_FOREIGN_FILE")" "monerod"
assert_not_contains "no stop was attempted for another project's container" "$(cat "$LG_ORDER")" "stop:"
unset LG_FOREIGN_FILE
: >"$LG_ORDER"
printf 'tari\n' >"$LG_RUNNING_FILE"
printf 'TARI_GRPC_BIND=127.0.0.1\nMONERO_RPC_BIND=0.0.0.0\nMONERO_ZMQ_BIND=127.0.0.1\n' >"$LGD/.env.tari-off"
cp "$LGD/.env" "$LGD/.env.transition-original"
cp "$LGD/.env.tari-off" "$LGD/.env"
LG_LIVE=1 LG_COMPOSE_RC=1 lg 'compose_up -d' >/dev/null
lg_rc=$?
assert_eq "Tari switch-off reaches Compose after stopping Tari" "$lg_rc" "1"
assert_eq "Tari is stopped when its old gRPC bind is withdrawn" "$(cat "$LG_RUNNING_FILE")" ""
assert_eq "Tari stops after the rule refresh and before failed Compose" \
    "$(cat "$LG_ORDER")" $'restore\nstop:tari\ncompose'
printf 'tari\n' >"$LG_RUNNING_FILE"
: >"$LG_ARGS_LOG"
LG_LIVE=1 lg 'compose_up -d tor' >/dev/null
assert_contains "a scoped up restarts a node switched to loopback" "$(cat "$LG_ARGS_LOG")" " tor tari"
printf 'tari\n' >"$LG_RUNNING_FILE"
: >"$LG_ARGS_LOG"
lg_out="$(PITHEAD_KEEP_RUNNING=tari LG_LIVE=1 lg 'compose_up -d tor')"
lg_rc=$?
assert_eq "a switch-off stop refuses the keep-running promise" "$lg_rc" "1"
assert_contains "the stopped node is named" "$lg_out" "Cannot keep tari running"
assert_eq "a kept node is not silently restarted" "$(cat "$LG_ARGS_LOG")" ""

mv "$LGD/.env.transition-original" "$LGD/.env"
unset LG_RUNNING_FILE
