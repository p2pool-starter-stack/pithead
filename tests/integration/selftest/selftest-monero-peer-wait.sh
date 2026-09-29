#!/usr/bin/env bash
#
# Self-test for #2921: the stranded-Monero leg's peer wait must record what it saw. A wait that times
# out captures the tor-recover check and both log tails (redacted) BEFORE the restore, the leg still
# SKIPS (never passes, never fails) and injects no fault, and each poll logs one sample. Pure functions
# against stubs: no box, no docker.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-monero-stranded.sh
source "$HERE/../lib/run-monero-stranded.sh"

export BASELINE_CONFIG='{}'
CALLS="$(mktemp)"
trap 'rm -f "$CALLS"' EXIT
has_compose_profile() { return 0; }
env_on_box() { :; }
push_config() { echo push >>"$CALLS"; }
wait_status_ok() { return 0; }
wait_for() { # the peer wait times out; every other wait passes
    case "$3" in
        *"holding outgoing peers"*) _pred_monero_has_peers_sampled || true; return 1 ;;
        *) return 0 ;;
    esac
}
monero_health_field() { echo green; }
monero_strand_state() { echo "verdict 'green', peers 0"; }
monero_ns_ipt() { echo "ns-ipt $*" >>"$CALLS"; }
monero_hook_start() { :; }
monero_hook_stop() { :; }
now_s() { echo 0; }
pithead() { case "$*" in "tor-recover check") echo "check: peers 0 at 203.0.113.7 API_KEY=SECRETVALUE" ;; *) echo "pithead $*" >>"$CALLS" ;; esac; }
rx() {
    case "$1" in
        *"docker inspect -f '{{range"*) echo 172.20.0.5 ;;
        *"get_info"*) echo '{"out":0,"in":0,"height":1,"synchronized":true}' ;;
        *"logs --since"*) echo " 3 Bootstrapped 100% (done)" ;;
        *"logs --tail"*tor*) echo "tor line 198.51.100.9 onion" ;;
        *"logs --tail"*) echo "monerod line PASSWORD=hunter2" ;;
        *"State.Health.Status"*) echo "healthy since T" ;;
        *"StartedAt"*) echo "T" ;;
    esac
}

out="$(run_monero_stranded 2>&1)"
assert_contains "each poll logs a peer sample" "$out" "peer sample: monerod {\"out\":0,\"in\":0"
assert_contains "the sample names the tor state" "$out" "tor 60s:"
assert_contains "the timeout captures the tor-recover check" "$out" "tor-recover check: check: peers 0"
assert_contains "and the tor log tail" "$out" "tor: tor line"
assert_contains "and the monerod log tail" "$out" "monerod: monerod line"
if echo "$out" | grep -qE "hunter2|SECRETVALUE|198.51.100"; then it_fail "captured evidence is redacted" "a secret or address leaked"; else it_pass "captured evidence is redacted"; fi
assert_contains "the leg still skips, never passes" "$out" "strand a monerod that holds peers"
assert_eq "no fault was injected" "$(grep -c 'ns-ipt -I' "$CALLS")" "0"

echo "selftest-monero-peer-wait: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
