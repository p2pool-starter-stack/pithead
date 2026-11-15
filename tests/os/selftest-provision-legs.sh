#!/usr/bin/env bash
# Reserved-node leg selection (#4123): which phases run the consumer proof and its XvB routing
# leg. Pure harness controls: no containers, guests or network service.
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/tmp}}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/provision-legs-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2034 # sourced phase files read this global.
OS_RUN_SUITE=1 SCRIPT_DIR="$ROOT/tests/os"
ok() { printf '%s\n' "$*" >>"$work/pass"; }
bad() { printf '%s\n' "$*" >>"$work/fail"; }
info() { printf '%s\n' "$*" >>"$work/info"; }
# shellcheck source=tests/os/appliance-node-runtime-leg.sh
source "$ROOT/tests/os/appliance-node-runtime-leg.sh"
# shellcheck source=tests/os/phases/provision-initial.sh
source "$ROOT/tests/os/phases/provision-initial.sh"
phase_provision_xvb_routing() { bad "XvB routing leg ran while the consumer proof never applied"; }

unset PITHEAD_OS_MONERO_NODE_HOST PITHEAD_OS_MONERO_RPC_PORT PITHEAD_OS_MONERO_ZMQ_PORT
unset PITHEAD_OS_TARI_NODE_HOST PITHEAD_OS_TARI_GRPC_PORT

# The full provision phase (flag unset -> consumer) must still fail both rows without inputs.
pv_user=user pv_pass=pass OS_RESERVED_NODE_CONSUMER=1 phase_provision_reserved_node_legs
[ "$(wc -l <"$work/fail" | tr -d ' ')" = 2 ]
grep -q 'reserved-node inputs are missing' "$work/fail"
grep -q 'XvB routing leg NOT exercised' "$work/fail"
[ ! -e "$work/info" ]
: >"$work/fail"

pv_user=user pv_pass=pass phase_provision_reserved_node_legs
[ "$(wc -l <"$work/fail" | tr -d ' ')" = 2 ]
: >"$work/fail"

# A phase that consumes no reserved-node proof selects neither row and emits no skip.
pv_user=user pv_pass=pass OS_RESERVED_NODE_CONSUMER=0 phase_provision_reserved_node_legs
[ ! -s "$work/fail" ]
grep -q '#4123' "$work/info"

# The two heal phases declare the prelude non-consuming.
# shellcheck source=tests/os/phases/tor-heal.sh
source "$ROOT/tests/os/phases/tor-heal.sh"
# shellcheck source=tests/os/phases/pool-heal.sh
source "$ROOT/tests/os/phases/pool-heal.sh"
_phase_provision_initial() {
    printf '%s' "${OS_RESERVED_NODE_CONSUMER:-consumer}" >"$work/flag"
    return 1
}
phase_tor_heal >>"$work/out" 2>&1 || true
grep -qx 0 "$work/flag"
rm "$work/flag"
phase_p2pool_heal >>"$work/out" 2>&1 || true
grep -qx 0 "$work/flag"
rm "$work/flag"

# The provision phase declares the consumer by silence: it runs the legs by default (#4123).
if grep -q 'OS_RESERVED_NODE_CONSUMER' "$ROOT/tests/os/phases/provision.sh"; then exit 1; fi
grep -Fq '    phase_provision_reserved_node_legs' "$ROOT/tests/os/phases/provision-initial.sh"
bash -n "$ROOT/tests/os/phases/provision-initial.sh"
echo 'selftest-provision-legs: PASS'
