#!/usr/bin/env bash
# The lifecycle's real prefix must sample every restart/image-fixture boundary in order.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=tests/integration/lib/run-source-image.sh
source "$ROOT/tests/integration/lib/run-source-image.sh"
echo "== lifecycle sync-gate diagnostic boundary wiring =="
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
OUT_DIR=$fixture
IT_FAIL=0
# Execute the original lifecycle prefix through the real source-image runner; later pool/wallet
# legs do not concern these diagnostics and have their own complete lifecycle selftests.
eval "$(sed -n '/^run_lifecycle() {/,/    local cur_pool fp_before/p' "$ROOT/tests/integration/lib/run-lifecycle.sh" | sed '$d')
}"
rx() {
    case "$1" in
    *lifecycle_gate_sample_target\ *)
        local stage=${1##* }
        stage=${stage//\'/}
        printf 'lifecycle-gate: %s marker=absent snapshot_release=true p2pool=running proxy=running\n' "$stage"
        ;;
    *'source ./pithead'*)
        printf '%s\n' 'source-image: live old image differs from built declaration' \
            'Recreating xmrig-proxy: its container still uses the previous image.' \
            'source-image: guarded recreate matches declared image and Compose owner' \
            'source-image: original image restored'
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
assert_rc() { [ "$2" = "$3" ] || it_fail; }
assert_eq() { [ "$2" = "$3" ] || it_fail; }
assert_contains() { [[ "$2" == *"$3"* ]] || it_fail; }
pithead() { :; }
wait_status_ok() { :; }
tor_recovery_healthy_probe() { :; }
run_connection_announcements() { :; }
service_state() { echo 'running none'; }
svc_state_of() { printf '%s' "${1%% *}"; }
run_lifecycle
[ "$IT_FAIL" = 0 ]
[ "$(awk '{print $2}' "$fixture/lifecycle-gate.log")" = $'before-restart\nafter-restart\nbefore-image-down\nafter-image-up\nbefore-source-image' ]
echo 'selftest-lifecycle-gate-wiring: all five lifecycle/image boundaries passed'
