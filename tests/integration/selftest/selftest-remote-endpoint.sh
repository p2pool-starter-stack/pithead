#!/usr/bin/env bash
#
# Self-test for the remote-node endpoint overrides (#1491) — the ports resolve_overrides emits
# for monero.mode=remote, and run.sh's refusal of a host:port string.
#
# pithead renders monero.remote.host and monero.remote.rpc_port SEPARATELY
# (lib/pithead/99-remainder.sh), so a "host:port" passed as the host is appended to a second
# time and reaches the box as host:port:port. The harness could not express a non-default port
# at all before #1491, which is why remote mode could only ever be pointed at 18081/18083.
#
# These cases live in their own file rather than in selftest.sh because that file sits
# exactly on its recorded budget ceiling, and ceilings only go down.
#
# Run: tests/integration/selftest/selftest-remote-endpoint.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

assert_absent() { case "$2" in *"$3"*) it_fail "$1" "[$2] should not carry [$3]" ;; *) it_pass "$1" ;; esac }

echo "== remote endpoint: ports are emitted only when set, and only in remote mode (#1491) =="

BASELINE_PRUNE=1
REMOTE_MONERO_HOST="10.0.0.5"

# Unset ports must emit nothing, so the product's own defaults stand. A test that only checked
# the "set" case would pass just as well against code that hardcoded the defaults.
REMOTE_MONERO_RPC_PORT="" REMOTE_MONERO_ZMQ_PORT=""
resolve_overrides "monero.mode=remote"
assert_rc "remote resolves with a bare host" "$?" "0"
assert_contains "bare host is passed through" "$RESOLVED" "monero.remote.host=10.0.0.5"
assert_absent "no rpc_port override when unset" "$RESOLVED" "monero.remote.rpc_port"
assert_absent "no zmq_port override when unset" "$RESOLVED" "monero.remote.zmq_port"

REMOTE_MONERO_RPC_PORT="28081" REMOTE_MONERO_ZMQ_PORT="28083"
resolve_overrides "monero.mode=remote"
assert_rc "remote resolves with ports" "$?" "0"
assert_contains "rpc_port override is emitted" "$RESOLVED" "monero.remote.rpc_port=28081"
assert_contains "zmq_port override is emitted" "$RESOLVED" "monero.remote.zmq_port=28083"
assert_contains "host survives alongside the ports" "$RESOLVED" "monero.remote.host=10.0.0.5"

# The near-miss sibling: local mode must not pick the ports up just because they are set.
# Without this case the emission could be unconditional and every assertion above still passes.
resolve_overrides "monero.mode=local monero.prune=true"
assert_absent "local mode ignores rpc_port" "$RESOLVED" "monero.remote.rpc_port"
assert_absent "local mode ignores zmq_port" "$RESOLVED" "monero.remote.zmq_port"

# Ports are not a substitute for the host: the skip must still fire, naming the flag.
REMOTE_MONERO_HOST=""
resolve_overrides "monero.mode=remote"
assert_rc "ports alone do not satisfy remote mode" "$?" "1"
assert_contains "skip still names --remote-monero-host" "$SKIP_REASON" "--remote-monero-host"

echo "== run.sh refuses a host:port string for --remote-monero-host (#1491) =="

# Assert the REASON, not the exit code: run.sh also exits non-zero for "no --host/--local", so an
# rc-only case passes whether or not the host:port guard exists at all.
out=$(bash "$HERE/../run.sh" --remote-monero-host 10.0.0.5:18081 2>&1)
assert_rc "host:port is refused" "$?" "2"
assert_contains "refusal explains the bare-host rule" "$out" "BARE host or IP"

out=$(bash "$HERE/../run.sh" --remote-monero-host 'node;echo INJECTED' --local 2>&1)
assert_rc "Monero shell payload is refused before rendering" "$?" "2"
assert_contains "Monero refusal names the host grammar" "$out" "unsupported characters"

out=$(bash "$HERE/../run.sh" --remote-tari-host 'node"|.network.subnet="INJECTED' --local 2>&1)
assert_rc "Tari jq payload is refused before rendering" "$?" "2"
assert_contains "Tari refusal names the host grammar" "$out" "unsupported characters"

out=$(bash "$HERE/../run.sh" --remote-tari-host tari.example:18142 --local 2>&1)
assert_rc "Tari host:port is refused before rendering" "$?" "2"
assert_contains "Tari host:port refusal names the separate port" "$out" "grpc_port separately"

out=$(bash "$HERE/../e2e.sh" --remote-tari-host tari.example:18142 --help 2>&1)
assert_rc "e2e refuses a Tari host:port before preflight" "$?" "1"
assert_contains "e2e Tari refusal names the bare-host grammar" "$out" "bare hostname or IPv4"

out=$(bash "$HERE/../e2e.sh" --remote-monero-host 'node;echo INJECTED' --help 2>&1)
assert_rc "e2e refuses a remote host before preflight" "$?" "1"
assert_contains "e2e refusal names the host grammar" "$out" "unsupported characters"

out=$(bash "$HERE/../e2e.sh" --remote-monero-rpc-port abc --help 2>&1)
assert_rc "e2e refuses a remote port before preflight" "$?" "1"
assert_contains "e2e port refusal names the range" "$out" "1-65535"

REMOTE_NODE_VALUES=(node.example 28081)
out=$(printf 'failed at node.example:28081\n' | redact_remote_output)
assert_absent "remote hostname is masked from console output" "$out" "node.example"
assert_absent "remote port is masked from console output" "$out" "28081"
assert_contains "masked console output retains a useful marker" "$out" "<redacted-endpoint>"

out=$(bash "$HERE/../e2e.sh" candidate --harness-arg --host --help 2>&1)
assert_rc "harness arguments cannot replace the fixed target transport" "$?" "1"
assert_contains "transport override refusal names the unsupported value" "$out" "unsupported harness argument: --host"

out=$(bash "$HERE/../e2e.sh" candidate --harness-arg --scenario --harness-arg 'a\e[2J' --help 2>&1)
assert_rc "scenario values cannot inject terminal controls" "$?" "1"
assert_contains "scenario metacharacter refusal names the unsupported value" "$out" "unsupported harness argument"

out=$(bash "$HERE/../run.sh" --remote-monero-rpc-port 0 --local 2>&1)
assert_rc "port 0 is refused" "$?" "2"
assert_contains "port refusal names the range" "$out" "1-65535"

out=$(bash "$HERE/../run.sh" --remote-monero-rpc-port 99999 --local 2>&1)
assert_rc "port 99999 is refused" "$?" "2"
assert_contains "out-of-range port names the range" "$out" "1-65535"

# A non-numeric port needs its own case: without the *[!0-9]* guard the range check below it
# runs "[ abc -lt 1 ]", which errors rather than returning false, so the value is ACCEPTED.
out=$(bash "$HERE/../run.sh" --remote-monero-rpc-port abc --local 2>&1)
assert_rc "non-numeric port is refused" "$?" "2"
assert_contains "non-numeric port names the range" "$out" "1-65535"

out=$(bash "$HERE/../run.sh" --remote-monero-zmq-port 1x --local 2>&1)
assert_rc "part-numeric zmq port is refused" "$?" "2"
assert_contains "part-numeric port names the range" "$out" "1-65535"

out=$(bash "$HERE/../run.sh" --remote-monero-rpc-port $'1\e[2J' --local 2>&1)
assert_rc "port terminal-control payload is refused" "$?" "2"
assert_absent "port refusal does not echo terminal controls" "$out" $'\e'

echo ""
echo "selftest-remote-endpoint: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
