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
unset LG_RUNNING_FILE
