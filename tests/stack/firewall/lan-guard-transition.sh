# shellcheck shell=bash
# Sourced by lan-guard.sh with its stub engine and assertion helpers.
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
assert_eq "the stopped listener cannot survive failed Compose after its jump is removed" \
    "$(cat "$LG_ORDER")" $'stop:monerod\nrestore\ncompose'
: >"$LG_ORDER"
printf 'monerod\ntari\n' >"$LG_RUNNING_FILE"
LG_LIVE=1 LG_OLD_MONERO_RPC=0.0.0.0 LG_STOP_FAIL=1 lg 'compose_up -d' >/dev/null
lg_rc=$?
assert_eq "a failed stop refuses startup" "$lg_rc" "1"
assert_eq "a failed stop keeps the old firewall rule and never invokes Compose" \
    "$(cat "$LG_ORDER")" "stop:monerod"
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
    "$(cat "$LG_ORDER")" $'stop:123456789abc_monerod\nrestore\ncompose'
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
assert_eq "Tari stop precedes firewall replacement and failed Compose" \
    "$(cat "$LG_ORDER")" $'stop:tari\nrestore\ncompose'
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
