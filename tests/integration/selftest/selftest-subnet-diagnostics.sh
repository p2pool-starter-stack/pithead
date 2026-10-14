#!/usr/bin/env bash
# shellcheck disable=SC2034 # fixture globals consumed by sourced runner functions
# First-timeout collection must precede later probes and preserve baseline restoration.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-rigforge.sh
source "$HERE/../lib/run-rigforge.sh"
# shellcheck source=tests/integration/lib/run-state.sh
source "$HERE/../lib/run-state.sh"
td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT
echo "== bounded subnet first-timeout diagnostics and unchanged failure cleanup =="

python3 "$HERE/subnet-diagnostics-cases.py"
assert_rc 'typed diagnostics wire, redaction and command-bound contracts' "$?" 0

phase_case() (
    local stage="$1" collector_rc="$2"
    OUT_DIR="$td/$stage-$collector_rc"
    mkdir -p "$OUT_DIR"
    IT_MODE=local IT_FAIL=0 SKIP_MINING_ASSERTS=0 BASELINE_CONFIG='{}'
    env_on_box() { echo local_node; }
    has_compose_profile() { [ "$1" = local_node ]; }
    scenario_overrides() { echo 'network.subnet=198.51.100.0/24'; }
    render_scenario_config() { echo '{"dashboard":{"tari_required":true}}'; }
    push_config() { echo "config $1" >>"$OUT_DIR/order"; }
    pithead() { echo "pithead $*" >>"$OUT_DIR/order"; }
    wait_status_ok() {
        echo "wait status $1" >>"$OUT_DIR/order"
        [ "$stage" != status ]
    }
    wait_monero_synced() {
        echo "wait monero $1" >>"$OUT_DIR/order"
        [ "$stage" != monero-sync ]
    }
    wait_miner_running() {
        echo "wait miner $1" >>"$OUT_DIR/order"
        [ "$stage" != miner-release ]
    }
    wait_hashes_flowing() {
        echo "wait hashes $1" >>"$OUT_DIR/order"
        [ "$stage" != hashes ]
    }
    wait_tari_synced() {
        echo "wait tari $1" >>"$OUT_DIR/order"
        [ "$stage" != tari-sync ]
    }
    rx() {
        echo "collect $1" >>"$OUT_DIR/order"
        printf '{"probe":"fixture","summary":{"safe":true}}\n'
        return "$collector_rc"
    }
    assert_subnet_live() { echo subnet-live >>"$OUT_DIR/order"; }
    assert_running_state() {
        [ "$stage" != mining-release ] || capture_subnet_timeout_once mining-release
        # Later failure must not overwrite the first capture or skip assertions.
        capture_subnet_timeout_once later-timeout
        echo battery >>"$OUT_DIR/order"
        it_fail 'original UID/TLS failure' 'still binding'
    }
    # Do not collect on the success path in this fixture.
    if [ "$stage" = ready ]; then assert_running_state() { echo battery >>"$OUT_DIR/order"; }; fi
    capture_artifacts() { echo general-artifacts >>"$OUT_DIR/order"; }
    run_subnet_scenario >/dev/null
    if [ "$stage" = ready ]; then
        [ ! -e "$OUT_DIR/subnet-first-timeout" ] || exit 1
        [ "$IT_FAIL" = 0 ] || exit 1
    else
        [ "$IT_FAIL" = 1 ] || exit 1
        [ "$(grep -c '^collect ' "$OUT_DIR/order")" = 1 ] || exit 1
        grep -q "^stage=$stage " "$OUT_DIR/subnet-first-timeout/trigger.txt" || exit 1
        grep -Fxq "collector_exit=$collector_rc" "$OUT_DIR/subnet-first-timeout/collector-exit.txt" || exit 1
        local collected battery
        collected=$(grep -n '^collect ' "$OUT_DIR/order" | cut -d: -f1)
        battery=$(grep -n '^battery$' "$OUT_DIR/order" | cut -d: -f1)
        [ "$collected" -lt "$battery" ] || exit 1
    fi
    # The original wait limits and unconditional down/apply restoration remain in order.
    grep -Fxq 'wait status 300' "$OUT_DIR/order" || exit 1
    grep -Fxq 'wait monero 120' "$OUT_DIR/order" || exit 1
    grep -Fxq 'wait miner 180' "$OUT_DIR/order" || exit 1
    grep -Fxq 'wait hashes 300' "$OUT_DIR/order" || exit 1
    grep -Fxq 'wait tari 300' "$OUT_DIR/order" || exit 1
    [ "$(grep -c '^pithead down$' "$OUT_DIR/order")" = 2 ] || exit 1
    [ "$(grep -c '^pithead apply -y$' "$OUT_DIR/order")" = 2 ] || exit 1
    [ "$(tail -n4 "$OUT_DIR/order" | head -n1)" = 'config {}' ] || exit 1
)
for stage in ready status monero-sync miner-release hashes tari-sync mining-release; do
    phase_case "$stage" 0
    assert_rc "first timeout capture and restoration: $stage" "$?" 0
done
phase_case status 124
assert_rc 'collector timeout preserves original assertions and restoration' "$?" 0

# Execute the actual running-state entry through its first live service assertion.
(
    OUT_DIR="$td/battery" SUBNET_TIMEOUT_ACTIVE=1 SUBNET_TIMEOUT_CAPTURED=0
    jq_get() { case "$2" in .monero.mode | .tari.mode) echo local ;; *) echo false ;; esac }
    clearnet_flag_effective() { echo false; }
    wait_for() {
        printf '%s %s\n' "$1" "$2" >"$td/release-wait"
        return 1
    }
    rx() {
        echo diagnostic >>"$td/battery-order"
        return 1
    }
    running_services() {
        echo samples >>"$td/battery-order"
        echo p2pool
    }
    expected_services() { echo p2pool; }
    it_pass() {
        echo assertion >>"$td/battery-order"
        exit 0
    }
    assert_running_state subnet '{}'
)
assert_rc 'actual battery still executes assertions after collector failure' "$?" 0
assert_eq 'first release wait retains its 1500s deadline and 5s cadence' "$(cat "$td/release-wait")" '1500 5'
assert_eq 'collector runs before live service sampling and assertions' "$(cat "$td/battery-order")" \
    $'diagnostic\nsamples\nassertion'

# A failed artifact write is also best-effort, and unrelated batteries never collect.
(
    OUT_DIR="$td/not-a-directory" SUBNET_TIMEOUT_ACTIVE=1 SUBNET_TIMEOUT_CAPTURED=0
    touch "$OUT_DIR"
    capture_subnet_timeout_once status >"$td/artifact-error.log" 2>&1
    grep -Fq "subnet first-timeout diagnostics: artifact directory creation failed" "$td/artifact-error.log"
    [ "$SUBNET_TIMEOUT_CAPTURED" = 1 ]
)
assert_rc 'artifact failure leaves the original control flow intact' "$?" 0
(
    unset OUT_DIR SUBNET_TIMEOUT_ACTIVE
    capture_subnet_timeout_once status
)
assert_rc 'unrelated running-state batteries cannot invoke subnet collection' "$?" 0
# Selected smoke phase must be discoverable/allowlisted and reject missing live proof.
(
    source "$HERE/../lib/run-cli.sh"
    IT_SSH_OPTS=() IT_MODE=local IT_REMOTE_DIR=. RUN_SUBNET_DIAGNOSTICS=0
    RIG_NAME="" RIG_HOST="" RIGFORGE_BOOTSTRAP_VERSION="" RUN_RIGFORGE_CONTROL=0 RUN_IMAGE_UPGRADE=0
    RUN_XVB_ROUTING=0 SAFETY_BACKUP=0 CANDIDATE_BUNDLE="" SKIP_MINING_ASSERTS=0
    validate_live_gate_args() { :; }
    parse_args --local --subnet-diagnostics
    [ "$RUN_SUBNET_DIAGNOSTICS" = 1 ]
)
assert_rc 'runner accepts the selected diagnostics smoke' "$?" 0
(
    source "$HERE/../lib/harness-args.sh"
    die() { exit 9; }
    MODE=targeted HARNESS_ARGS=(--subnet-diagnostics)
    validate_harness_args
    [ "$HARNESS_PHASE_ARGS" = ' --subnet-diagnostics' ]
)
assert_rc 'e2e wrapper forwards only the allowlisted diagnostics flag' "$?" 0
for smoke_case in valid missing restricted interrupted missing-containers missing-counters; do
    (
        OUT_DIR="$td/smoke-$smoke_case" IT_FAIL=0
        collect_subnet_diagnostics() {
            mkdir -p "$1"
            for probe in rendered-network container-monerod container-tari container-tor container-dashboard container-p2pool container-xmrig-proxy monero-admin-info monero-get_connections monero-sync_info tor-circuit-status tor-stream-status tor-build-history live-network monero-proxy tor-control-bind firewall-enforcement; do
                [ "$smoke_case" != missing-containers ] || [[ "$probe" != container-* ]] || continue
                [ "$smoke_case" != missing ] || [ "$probe" != tor-stream-status ] || continue
                if [ "$probe" = monero-admin-info ]; then
                    visibility=unrestricted
                    [ "$smoke_case" != restricted ] || visibility=unverified
                    printf '{"probe":"%s","summary":{"rpc_visibility":"%s"}}\n' "$probe" "$visibility"
                else printf '{"probe":"%s","summary":{}}\n' "$probe"; fi
            done >"$1/summary.jsonl"
            [ "$smoke_case" = missing-counters ] || echo '{"probe":"firewall-iptables","summary":{"count":3}}' >>"$1/summary.jsonl"
            [ "$smoke_case" = interrupted ] || echo '{"probe":"collection","complete":true}' >>"$1/summary.jsonl"
        }
        run_subnet_diagnostics_smoke >/dev/null
        if [ "$smoke_case" = valid ]; then [ "$IT_FAIL" = 0 ]; else [ "$IT_FAIL" -gt 0 ]; fi
    )
    assert_rc "live smoke assertions remain binding: $smoke_case" "$?" 0
done
echo "selftest-subnet-diagnostics: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
