# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance defaults domain (#1105 Phase 1, appliance lane): two sections covering what a first
# boot writes into a config the operator did not finish. apply_appliance_defaults fills tor
# .auto_heal only where the key is ABSENT — an operator who wrote false meant it — and turns the
# dashboard control channel on only when a password is actually present, because the appliance has
# no shell and no ssh, so the channel is the only way to change a payout address, and an enabled
# channel with an empty password is the exact pair parse_and_validate_config refuses (#1066). The
# last case walks the documented "No login" first-boot sequence in the order the appliance runs it
# and asserts the forbidden pair is never produced.
# Sourced by tests/stack/run.sh.
#
# DISCLOSURE — the opening section is a provisioning preflight, and the file name does not say so.
# preflight_remote_nodes (dial every configured remote node before provisioning commits; name the
# host:port and point at the grpc_lan_access switch on failure) is thematically PROVISIONING and
# belongs beside test-control-provisioning.sh. It is here because contiguity outranks the label:
# the test-appliance-identity.sh source stanza sits BETWEEN that section and the provisioning
# block, and moving this section across it would make the provisioning cut non-contiguous — which
# would break the order-preserving-concat proof this whole split rests on. Ruled by the controller
# rather than assumed; a 14-line file of its own is below any sensible floor. Direct precedent:
# Phase 2's 21-doctor-stack-checks.sh carries three non-doctor helpers for the same reason.
#
# The block is contiguous and its source stanza sits at its exact former position, so execution
# order is unchanged — a pure relocation, not a regrouping.
#
# Re-derivations. This file reads NO ambient name: every variable it reads it assigns itself —
# $PFSB and $ADSB (both mktemp -d, both removed and unset at the end of their section) and $out.
# Provider functions called: run_sourced, assert_rc, assert_eq, assert_contains. There is
# deliberately no `: "${NAME:?}"` guard line, because there is nothing to guard. $PFSB is also
# assigned in test-appliance-install.sh — its own mktemp -d, unset at the end of its own section.
# That is a name reused downstream, not a value shared with it, and that file assigns before it
# reads either way.

echo "== unit: preflight_remote_nodes dials before provisioning commits =="
mk_tmpdir PFSB
printf '{"monero":{"mode":"local"},"tari":{"mode":"local"}}' >"$PFSB/local.json"
run_sourced "$PFSB" preflight_remote_nodes "$PFSB/local.json" >/dev/null 2>&1
assert_rc "all-local config -> nothing to dial, rc 0" "$?" "0"
# 127.0.0.1:1 — reliably closed; the dial must fail fast and NAME the endpoint.
printf '{"monero":{"mode":"local"},"tari":{"mode":"remote","remote":{"host":"127.0.0.1","grpc_port":1}}}' >"$PFSB/bad.json"
out=$(run_sourced "$PFSB" preflight_remote_nodes "$PFSB/bad.json" 2>/dev/null)
assert_rc "unreachable remote Tari -> rc 1" "$?" "1"
assert_contains "failure names host and port" "$out" "127.0.0.1:1"
assert_contains "failure points at the LAN-access switch" "$out" "grpc_lan_access"

# The ZMQ half. A TCP connect proves reachability and NOTHING else, and on the ZMQ port that gap
# is load-bearing: docker's userland proxy binds a published host port and accepts the connection
# itself, so a containerised node whose publisher failed to bind answers the dial rc 0. The
# verdict is pure over the greeting the peer sent, so every failure class is a fixture here
# rather than a socket. The first is CAPTURED from a live monerod; the rest are the shapes a
# live node will not produce.
PFZ_LIVE=ff00000000000000007f03014e554c4c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
PFZ_READY_PUB=04190552454144590b536f636b65742d5479706500000003505542
PFZ_READY_SUB=04190552454144590b536f636b65742d5479706500000003535542
PFZ_HTTP=485454502f312e312034303020426164205265717565737400000000000000000000000000000000000000000000000000000000000000000000000000000000
PFZ_ZMTP2=ff00000000000000007f01004e554c4c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
run_sourced "$PFSB" zmq_greeting_ok "$PFZ_LIVE"
assert_rc "a live monerod greeting is accepted" "$?" "0"
# THE case the dial cannot see: an accept() with no greeting is a published-but-dead port.
run_sourced "$PFSB" zmq_greeting_ok ""
assert_rc "an accept() that sends no greeting is refused" "$?" "1"
run_sourced "$PFSB" zmq_greeting_ok "ff0000"
assert_rc "a truncated greeting is refused, not read past its end" "$?" "1"
run_sourced "$PFSB" zmq_greeting_ok "$PFZ_HTTP"
assert_rc "a listener that is not ZMQ at all is refused" "$?" "1"
run_sourced "$PFSB" zmq_greeting_ok "$PFZ_ZMTP2"
assert_rc "a ZMTP 2 peer is refused — the READY exchange needs 3.x" "$?" "1"
run_sourced "$PFSB" zmq_greeting_ok "${PFZ_LIVE:0:24}504c41494e${PFZ_LIVE:34}"
assert_rc "a PLAIN-mechanism peer is refused before READY" "$?" "1"
run_sourced "$PFSB" zmq_greeting_ok "${PFZ_LIVE:0:32}01${PFZ_LIVE:34}"
assert_rc "a NULL mechanism with nonzero padding is refused before READY" "$?" "1"
run_sourced "$PFSB" zmq_greeting_ok "${PFZ_LIVE:0:64}01${PFZ_LIVE:66}"
assert_rc "an as-server peer is refused before READY" "$?" "1"
run_sourced "$PFSB" zmq_greeting_ok "${PFZ_LIVE:0:66}01${PFZ_LIVE:68}"
assert_rc "a greeting with nonzero filler is refused before READY" "$?" "1"
run_sourced "$PFSB" zmq_ready_is_publisher "$PFZ_READY_PUB"
assert_rc "a READY frame advertising PUB is accepted" "$?" "0"
run_sourced "$PFSB" zmq_ready_is_publisher "$PFZ_READY_SUB"
assert_rc "a READY frame advertising SUB is refused" "$?" "1"

# Wiring, both directions, with no socket: stub `timeout` so every dial answers rc 0 and the
# greeting read returns whatever the case supplies. An empty return is exactly the
# published-but-dead shape — reachable, and nothing behind it.
printf '{"monero":{"mode":"remote","remote":{"host":"127.0.0.1","rpc_port":18081,"zmq_port":18083}},"tari":{"mode":"local"}}' >"$PFSB/zmq.json"
out=$(
    cd "$PFSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    timeout() { return 0; }
    remote_node_address() { printf '127.0.0.1'; }
    monero_rpc_speaks() { return 0; }
    preflight_remote_nodes "$PFSB/zmq.json" 2>/dev/null
)
assert_rc "reachable but no ZMTP greeting -> rc 1" "$?" "1"
assert_contains "the refusal says nothing there speaks ZMQ" "$out" "speaks ZMQ"
assert_contains "the refusal names the ZMQ port" "$out" "18083"
# The same run with a live greeting and publisher READY must PASS.
out=$(
    cd "$PFSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    timeout() { printf '%s\n%s' "$PFZ_LIVE" "$PFZ_READY_PUB"; }
    remote_node_address() { printf '127.0.0.1'; }
    monero_rpc_speaks() { return 0; }
    preflight_remote_nodes "$PFSB/zmq.json" 2>/dev/null
)
assert_rc "reachable ZMQ publisher -> rc 0" "$?" "0"

# The host-side check is the trusted re-check used by firstboot and dashboard config commits.
# It must match the newer Python wizard probe on auth, response bounds and get_info shape.
printf '{"monero":{"mode":"remote","node_username":"remoteuser","node_password":"remotepass","remote":{"host":"node.example","rpc_port":18081,"zmq_port":18083}},"tari":{"mode":"local"}}' >"$PFSB/rpc.json"
out=$(
    cd "$PFSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    timeout() {
        printf '%s' "$*" >"$PFSB/curl.args"
        cat >"$PFSB/curl.stdin"
        printf '{"status":"OK","nettype":"mainnet","height":10,"target_height":11}\n200'
    }
    _resolve_host_ips() { printf '192.168.50.8\n'; }
    zmq_endpoint_is_publisher() {
        printf '%s' "$1" >"$PFSB/zmq.host"
        return 0
    }
    preflight_remote_nodes "$PFSB/rpc.json"
    printf '%s' "$NODE_PROBE_REASON"
)
assert_eq "host preflight accepts authenticated, well-formed get_info" "$out" "ok"
assert_contains "RPC re-check enables Digest auth" "$(cat "$PFSB/curl.args")" "--digest"
assert_not_contains "RPC password is absent from process argv" "$(cat "$PFSB/curl.args")" "remotepass"
assert_contains "RPC login is supplied through curl stdin config" "$(cat "$PFSB/curl.stdin")" "remoteuser:remotepass"
assert_contains "RPC re-check caps the response body" "$(cat "$PFSB/curl.args")" "--max-filesize 1048576"
assert_contains "RPC re-check bypasses ambient HTTP proxies" "$(cat "$PFSB/curl.args")" "--noproxy *"
assert_contains "RPC uses the resolved address" "$(cat "$PFSB/curl.args")" "http://192.168.50.8:18081/get_info"
assert_eq "ZMQ uses that same resolved address" "$(cat "$PFSB/zmq.host")" "192.168.50.8"
run_sourced "$PFSB" remote_node_ip_allowed 8.8.8.8 true
assert_rc "default Tor-egress policy refuses a public node address" "$?" "1"
run_sourced "$PFSB" remote_node_ip_allowed 192.168.50.8 true
assert_rc "default Tor-egress policy accepts a LAN node address" "$?" "0"
run_sourced "$PFSB" remote_node_ip_allowed 8.8.8.8 false
assert_rc "an explicit Tor-egress opt-out accepts a public node address" "$?" "0"
run_sourced "$PFSB" remote_node_ip_allowed ::ffff:127.0.0.1 false
assert_rc "an IPv4-mapped loopback address is always refused" "$?" "1"
run_sourced "$PFSB" remote_node_ip_allowed 100::1 false
assert_rc "a reserved IPv6 address is always refused" "$?" "1"
out=$(
    cd "$PFSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    timeout() { return 2; }
    zmq_endpoint_is_publisher 192.168.50.8 18083
    printf '%s' "$NODE_PROBE_REASON"
)
assert_eq "a malformed ZMQ exchange is a protocol failure" "$out" "protocol"
out=$(
    cd "$PFSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    timeout() { printf '{}\n200'; }
    monero_rpc_speaks "$PFSB/rpc.json" node.example 18081
    printf '%s' "$NODE_PROBE_REASON"
)
assert_eq "JSON that is not usable get_info -> protocol" "$out" "protocol"
out=$(
    cd "$PFSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    timeout() { printf '{"status":"OK","nettype":"mainnet","height":10.0,"target_height":11}\n200'; }
    monero_rpc_speaks "$PFSB/rpc.json" node.example 18081
    printf '%s' "$NODE_PROBE_REASON"
)
assert_eq "integral JSON floats do not pass as integer heights" "$out" "protocol"
out=$(
    cd "$PFSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    timeout() { return 63; }
    monero_rpc_speaks "$PFSB/rpc.json" node.example 18081
    printf '%s' "$NODE_PROBE_REASON"
)
assert_eq "an over-cap response is refused as unusable" "$out" "unusable"
rm -rf "$PFSB"
unset PFSB out PFZ_LIVE PFZ_READY_PUB PFZ_READY_SUB PFZ_HTTP PFZ_ZMTP2

echo "== unit: appliance defaults (tor.auto_heal) =="
# Applied only where ABSENT: an operator who wrote false meant it.
mk_tmpdir ADSB
printf '{"monero":{"wallet_address":"x"}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "absent auto_heal -> enabled" "$(jq -r '.tor.auto_heal' "$ADSB/config.json")" "true"
printf '{"tor":{"auto_heal":false}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "explicit false is respected" "$(jq -r '.tor.auto_heal' "$ADSB/config.json")" "false"
printf '{"tor":{"data_dir":"/x"}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "other tor keys survive" "$(jq -r '.tor.data_dir' "$ADSB/config.json")" "/x"

# dashboard.control.enabled had NO coverage, which is how #1066 shipped. The appliance turns the
# control channel on because it has no other way in — but only behind a login, because an
# unauthenticated config editor can change the payout wallet and run `apply`, which is exactly
# what parse_and_validate_config refuses. The wizard's strip_defaults drops any answer equal to
# the reference default, and the reference has control.enabled false, so the key is absent from
# EVERY submission: injecting unconditionally built the forbidden pair on the "No login" answer
# and dead-ended first boot after the operator was told provisioning had started.
printf '{"dashboard":{"auth":{"password":"a-real-password"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "a password present -> the control channel is turned on" "$(jq -r '.dashboard.control.enabled' "$ADSB/config.json")" "true"
printf '{"dashboard":{"auth":{"password":""}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "no password -> the control channel is NOT turned on (#1066)" "$(jq -r '.dashboard.control.enabled // "absent"' "$ADSB/config.json")" "absent"
printf '{"dashboard":{"control":{"enabled":false},"auth":{"password":"a-real-password"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "an explicit control.enabled false is respected" "$(jq -r '.dashboard.control.enabled' "$ADSB/config.json")" "false"
# The whole first-boot sequence for the documented "No login" answer, in the order the appliance
# runs it. The invariant is the one the validator enforces: this machine must never hand itself a
# config carrying an enabled control channel and no password.
mkdir -p "$ADSB/spool"
printf 'none' >"$ADSB/spool/auth-mode"
printf '{"monero":{"wallet_address":"x"},"dashboard":{"auth":{"username":"admin"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" ensure_appliance_dashboard_password "$ADSB/spool" >/dev/null 2>&1
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "\"No login\" leaves the password empty, as asked" "$(jq -r '.dashboard.auth.password // ""' "$ADSB/config.json")" ""
assert_eq "\"No login\" never produces the pair the validator refuses (#1066)" \
    "$(jq -r 'if (.dashboard.control.enabled == true) and ((.dashboard.auth.password // "") == "") then "forbidden-pair" else "ok" end' "$ADSB/config.json")" "ok"
# ...and the same sequence WITH a login still ends up configurable, which is the whole reason the
# appliance turns the channel on: no shell, no ssh, no other way to change a payout address.
rm -f "$ADSB/spool/auth-mode"
printf '{"monero":{"wallet_address":"x"},"dashboard":{"auth":{"username":"admin"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" ensure_appliance_dashboard_password "$ADSB/spool" >/dev/null 2>&1
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "a generated login leaves the machine configurable" "$(jq -r '.dashboard.control.enabled' "$ADSB/config.json")" "true"
rm -rf "$ADSB"
unset ADSB
