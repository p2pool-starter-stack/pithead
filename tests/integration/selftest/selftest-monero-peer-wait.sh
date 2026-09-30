#!/usr/bin/env bash
#
# Self-test for #2921's harness half. The stranded-Monero leg reads peers from the in-container helper
# (the published RPC is restricted and answers 0 for every count), records what it saw on each poll of
# the peer wait, captures the tor-recover check and the log tails (redacted) BEFORE the restore, still
# SKIPS (never passes, never fails) and injects no fault when there is no peer, and proves the RPC
# boundary. Pure functions against stubs: no box, no docker.
#
set -uo pipefail

echo "== selftest: Monero peer wait and RPC boundary =="

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
    *"holding outgoing peers"*)
        _pred_monero_has_peers_sampled || true
        return 1
        ;;
    *) return 0 ;;
    esac
}
monero_health_field() { echo green; }
monero_strand_state() { echo "verdict 'green', peers 0"; }
monero_ns_ipt() { echo "ns-ipt $*" >>"$CALLS"; }
monero_hook_start() { :; }
monero_hook_stop() { :; }
now_s() { echo 0; }
pithead() { case "$*" in "tor-recover check") echo "check: peers 0 at 203.0.113.7 API_KEY=SECRETVALUE" ;; *) echo "pithead $*" >>"$CALLS" ;; esac }
# What the box answers. PEERS is the helper's output ("" = no reading); the boundary knobs break one
# property each. The restricted get_info below always carries zeros: nothing may read them as peers.
PEERS='{"outgoing":0,"incoming":0,"white":0,"grey":0}'
ADMIN_UNAUTH=401 HOST_ADMIN=000 HOST_ADMIN6=000 HOST_PUBLISH='' BRIDGE_ADMIN=000 BRIDGE_ADMIN6=000 PUB_UNAUTH=401 PUB_RESTRICTED=true CONTAINER_REACHES=1 CONTAINER_REACHES6=1 V6=false
NETS='{"mining_net":{"IPAddress":"172.20.0.26","GlobalIPv6Address":""}}'
ADVERTISED_RPC=18081
rx() {
    case "$1" in
    *monero-p2p-rpc-port.py*) printf '%s' "$ADVERTISED_RPC" ;;
    *monerod-peers.sh*) printf '%s' "$PEERS" ;;
    *"docker inspect -f '{{json .NetworkSettings.Networks}}' monerod"*) printf '%s' "$NETS" ;;
    *"docker network inspect"*) printf '%s' "$V6" ;;
    *"docker inspect -f '{{range"*monerod*) echo 172.20.0.26 ;;
    *"docker inspect -f '{{range"*) echo 172.20.0.5 ;;
    *"docker exec monerod curl"*) printf '%s' "$ADMIN_UNAUTH" ;;
    *"docker port monerod 18085"*) printf '%s' "$HOST_PUBLISH" ;;
    *"docker exec dashboard python3"*"2001:db8"*) [ "$CONTAINER_REACHES6" = 1 ] && return 1 || return 0 ;;
    *"docker exec dashboard python3"*) [ "$CONTAINER_REACHES" = 1 ] && return 1 || return 0 ;;
    *"http://127.0.0.1:18085"*) printf '%s' "$HOST_ADMIN" ;;
    *"[::1]:18085"*) printf '%s' "$HOST_ADMIN6" ;;
    *"172.20.0.26:18085"*) printf '%s' "$BRIDGE_ADMIN" ;;
    *"[2001:db8::26]:18085"*) printf '%s' "$BRIDGE_ADMIN6" ;;
    *"-w"*"127.0.0.1:18081/get_info"*) printf '%s' "$PUB_UNAUTH" ;;
    *"restricted, o:"*) printf '{"restricted":%s,"o":0}' "$PUB_RESTRICTED" ;;
    *"logs --since"*) echo " 3 Bootstrapped 100% (done)" ;;
    *"logs --tail"*tor*) echo "tor line 198.51.100.9 onion" ;;
    *"logs --tail"*) echo "monerod line PASSWORD=hunter2" ;;
    *"State.Health.Status"*) echo "healthy since T" ;;
    *"StartedAt"*) echo "T" ;;
    esac
}

echo "== the peer wait: samples, diagnostics, a skip and no fault =="
out="$(run_monero_stranded 2>&1)"
assert_contains "each poll logs the helper's counts" "$out" 'peer sample: monerod {"outgoing":0,"incoming":0'
assert_contains "the sample names the tor state" "$out" "tor 60s:"
assert_contains "the timeout captures the tor-recover check" "$out" "tor-recover check: check: peers 0"
assert_contains "and the tor log tail" "$out" "tor: tor line"
assert_contains "and the monerod log tail" "$out" "monerod: monerod line"
if echo "$out" | grep -qE "hunter2|SECRETVALUE|198.51.100"; then it_fail "captured evidence is redacted" "a secret or address leaked"; else it_pass "captured evidence is redacted"; fi
assert_contains "the leg still skips, never passes" "$out" "strand a monerod that holds peers"
assert_eq "no fault was injected" "$(grep -c 'ns-ipt -I' "$CALLS")" "0"

echo "== the peer predicates read only the helper =="
PEERS='{"outgoing":7,"incoming":2,"white":9,"grey":4}'
assert_eq "outgoing is the helper's count" "$(monero_out_peers)" "7"
_pred_monero_has_peers && it_pass "peers present" || it_fail "peers present" "has_peers false at 7"
_pred_monero_zero_out && it_fail "peers present is not zero" "zero_out true at 7" || it_pass "peers present is not zero"
PEERS='{"outgoing":0,"incoming":0,"white":0,"grey":0}'
_pred_monero_zero_out && it_pass "a real zero reads as zero" || it_fail "a real zero reads as zero" "zero_out false at 0"
_pred_monero_has_peers && it_fail "a real zero is not peers" "has_peers true at 0" || it_pass "a real zero is not peers"
PEERS=""
_pred_monero_zero_out && it_fail "no reading is not zero" "zero_out true with no helper output" || it_pass "no reading is not zero"
_pred_monero_has_peers && it_fail "no reading is not peers" "has_peers true with no helper output" || it_pass "no reading is not peers"

echo "== the RPC boundary rows =="
boundary() { assert_monero_rpc_boundary 2>&1; }
PEERS='{"outgoing":3,"incoming":0,"white":1,"grey":1}'
good="$(boundary)"
assert_contains "a correct box passes the helper row" "$good" "reads real counts from the admin listener"
case "$good" in *"✗"*) it_fail "a correct box has no failing row" "$good" ;; *) it_pass "a correct box has no failing row" ;; esac
case_fails() { # <VAR=value> <row text>: break one property, expect a failing row, restore it
    local var=${1%%=*} saved r
    saved="${!var}"
    printf -v "$var" '%s' "${1#*=}"
    r="$(boundary)"
    printf -v "$var" '%s' "$saved"
    assert_contains "$2" "$r" "✗"
}
case_fails "ADMIN_UNAUTH=200" "an admin listener that answers without a login fails"
case_fails "ADVERTISED_RPC=18085" "an advertised admin RPC port fails"
case_fails "ADVERTISED_RPC=" "an unavailable advertisement fails"
case_fails "HOST_ADMIN=200" "an admin listener published on the host loopback fails"
case_fails "HOST_PUBLISH=18085/tcp" "a host or LAN publication of the admin listener fails"
case_fails "HOST_ADMIN6=200" "an admin listener open on IPv6 loopback fails"
case_fails "BRIDGE_ADMIN=401" "an admin listener reachable on the bridge address fails"
case_fails 'NETS={}' "a missing bridge address fails"
case_fails 'NETS={"mining_net":{"IPAddress":""}}' "an empty bridge address fails"
case_fails 'V6=true' "an enabled IPv6 bridge with no address fails"
V6=true
NETS='{"mining_net":{"IPAddress":"172.20.0.26","GlobalIPv6Address":"2001:db8::26"}}'
case_fails "BRIDGE_ADMIN6=401" "an admin listener reachable on the IPv6 bridge fails"
case_fails "CONTAINER_REACHES6=0" "another container reaching the IPv6 admin listener fails"
V6=false
NETS='{"mining_net":{"IPAddress":"172.20.0.26","GlobalIPv6Address":""}}'
case_fails "PUB_UNAUTH=200" "a published listener that answers without a login fails"
case_fails "PUB_RESTRICTED=false" "an unrestricted published listener fails"
case_fails "CONTAINER_REACHES=0" "another container reaching the admin listener fails"
PEERS=""
assert_contains "no helper reading fails the helper row" "$(boundary)" "✗"

echo "selftest-monero-peer-wait: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
