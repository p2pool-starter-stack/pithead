#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=tests/integration/lib/run-source-image.sh
source "$ROOT/tests/integration/lib/run-source-image.sh"
echo "== lifecycle transition and image-fixture boundary wiring =="
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
OUT_DIR=$fixture
IT_FAIL=0
wallet_proof_calls=0
recovery_proof_calls=0
recovery_proof_rc=0
node_recovered=0
node_recovery_rc=0
monero_running=1
image_up_rc=0
source_rc=0
trace() { printf '%s\n' "$1" >>"$fixture/events"; }
eval "$(sed -n '/^run_lifecycle() {/,/    restore_tls_before=/p' "$ROOT/tests/integration/lib/run-lifecycle.sh" | sed '$d')
}"
rx() {
    case "$1" in
    *lifecycle_gate_sample_target\ *)
        local stage=${1##* }
        stage=${stage//\'/}
        trace "$stage"
        printf 'lifecycle-gate: %s marker=absent snapshot_release=true p2pool=running proxy=running\n' "$stage"
        ;;
    *'source ./pithead'*)
        trace source-fixture
        [ "$source_rc" = 0 ] || return "$source_rc"
        printf '%s\n' 'source-image: live old image differs from built declaration' \
            'Recreating xmrig-proxy: its container still uses the previous image.' \
            'source-image: guarded recreate matches declared image and Compose owner' \
            'source-image: original image restored'
        ;;
    'docker compose stop monerod')
        monero_running=0
        trace node-down
        ;;
    'docker compose start monerod')
        monero_running=1 node_recovered=1
        trace node-start
        ;;
    'docker compose config --images') echo fixture-docker-socket-proxy ;;
    'docker image inspect --format '*) echo fixture-image ;;
    *) return 0 ;;
    esac
}
quote_arg() { printf "'%s'" "$1"; }
redact() { cat; }
it_step() { :; }
it_log() { :; }
it_pass() { :; }
it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
capture_artifacts() { trace capture; }
assert_rc() { [ "$2" = "$3" ] || it_fail; }
assert_eq() { [ "$2" = "$3" ] || it_fail; }
assert_contains() { [[ "$2" == *"$3"* ]] || it_fail; }
pithead() {
    case "$1" in
    status)
        [ "$monero_running" = 1 ] || return 1
        [ "$node_recovered" = 0 ] || return "$node_recovery_rc"
        ;;
    up) return "$image_up_rc" ;;
    esac
}
wait_status_ok() { :; }
wait_for() { :; }
has_compose_profile() { return 0; }
env_on_box() { :; }
lifecycle_pool_start() {
    trace pool-start-main
    printf main
}
lifecycle_pool_apply() {
    [ "$1" = mini ]
    trace pool-ready-mini
}
upgrade_secret_fingerprints() { printf 'wallet=fingerprint'; }
pool_label() { printf Mini; }
assert_pool_switched() {
    [ "$2" = Mini ]
    trace pool-observed-mini
}
tor_recovery_healthy_probe() { :; }
prove_wallet_supersession() {
    [ "$(tail -n 1 "$fixture/lifecycle-gate.log" | awk '{print $2}')" = before-wizard-defaults ]
    wallet_proof_calls=$((wallet_proof_calls + 1))
}
prove_wallet_recovery() {
    [ "$wallet_proof_calls" = 1 ] || it_fail
    [ "$(tail -n 1 "$fixture/lifecycle-gate.log" | awk '{print $2}')" = before-wizard-defaults ] || it_fail
    recovery_proof_calls=$((recovery_proof_calls + 1))
    return "$recovery_proof_rc"
}
run_connection_announcements() { :; }
run_cli_wizard_defaults() { :; }
run_restore_dashboard_probe() { :; }
run_tari_background_sync() { :; }
assert_mining_probe_ready() {
    [ "$1" = "source image fixture (bench-ci#1276)" ]
    trace source-ready
}
service_state() { echo 'running none'; }
svc_state_of() { printf '%s' "${1%% *}"; }
lifecycle_rc=0
run_lifecycle || lifecycle_rc=$?
[ "$lifecycle_rc" = 0 ]
[ "$IT_FAIL" = 0 ]
[ "$wallet_proof_calls" = 1 ]
[ "$recovery_proof_calls" = 1 ]
[ "$(cat "$fixture/events")" = $'before-wizard-defaults\nbefore-restart\nafter-restart\npool-start-main\npool-ready-mini\npool-observed-mini\nnode-down\nnode-start\nbefore-image-down\nafter-image-up\nbefore-source-image\nsource-ready\nsource-fixture' ] || {
    echo 'FAIL: pool transition and node recovery must precede image fixtures'
    cat "$fixture/events"
    exit 1
}
echo 'selftest-lifecycle-gate-wiring: Main-to-Mini and node recovery precede both image fixtures'
for failure in wallet node image source; do
    IT_FAIL=0 wallet_proof_calls=0 recovery_proof_calls=0 recovery_proof_rc=0
    node_recovered=0 node_recovery_rc=0 monero_running=1 image_up_rc=0 source_rc=0
    : >"$fixture/lifecycle-gate.log"
    : >"$fixture/events"
    case "$failure" in
    wallet) recovery_proof_rc=1 ;;
    node) node_recovery_rc=1 ;;
    image) image_up_rc=1 ;;
    source) source_rc=1 ;;
    esac
    lifecycle_rc=0
    run_lifecycle || lifecycle_rc=$?
    case "$failure" in
    wallet)
        [ "$lifecycle_rc" != 0 ] && [ "$IT_FAIL" = 0 ] && [ "$recovery_proof_calls" = 1 ]
        [ "$(cat "$fixture/events")" = before-wizard-defaults ]
        ;;
    node)
        if [ "$lifecycle_rc" = 0 ] || [ "$IT_FAIL" != 1 ] || [ "$(tail -n 1 "$fixture/events")" != node-start ]; then
            echo 'FAIL: unhealthy node recovery must stop before image fixtures'
            cat "$fixture/events"
            exit 1
        fi
        ;;
    image | source)
        [ "$IT_FAIL" -gt 0 ]
        [ "$(sed -n '/^pool-start-main$/,/^node-start$/p' "$fixture/events")" = $'pool-start-main\npool-ready-mini\npool-observed-mini\nnode-down\nnode-start' ]
        grep -Fxq source-fixture "$fixture/events"
        [ "$failure" != source ] || [ "$lifecycle_rc" != 0 ]
        ;;
    esac
    echo "selftest-lifecycle-gate-wiring: $failure failure stays binding at its boundary"
done
