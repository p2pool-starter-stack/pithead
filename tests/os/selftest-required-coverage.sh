#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/tests/integration/lib.sh"
INTEGRATION_RUN_SUITE=1
source "$ROOT/tests/integration/lib/run-safety.sh"
OS_EXIT=$(sed -n '/^if \[ "\$PASS" -eq 0 \]/,$p' "$ROOT/tests/os/run.sh")
[ -n "$OS_EXIT" ]
run_verdict() (
    local kind=$1 strict=$2 missing=$3
    export PITHEAD_REQUIRE_COMPLETE=$strict
    PASS=3 FAIL=0 PHASE=fixture
    IT_PASS=3 IT_FAIL=0 IT_ALERT_REFUSED=0 OUT_DIR=fixture
    IT_SKIPPED_MISSING=$missing IT_SKIPPED_BY_DESIGN=1 IT_SKIPPED_COVERED=1
    IT_SKIPPED=0 IT_SKIPPED_PHASES=0 IT_SKIPPED_LEGS=$((missing + 2)) IT_SKIPPED_NAMES=""
    if [ "$kind" = os ]; then eval "$OS_EXIT"; else summary; fi
)
echo '== required coverage uses the actual OS exit gate and integration summary =='
for kind in os integration; do
    for strict in 0 1; do
        run_verdict "$kind" "$strict" 0 >/dev/null
        if run_verdict "$kind" "$strict" 1 >/dev/null 2>&1; then rc=0; else rc=$?; fi
        [ "$rc" -eq "$strict" ] || {
            echo "FAIL: $kind strict=$strict missing=1 returned $rc" >&2
            exit 1
        }
    done
    if run_verdict "$kind" invalid 0 >/dev/null 2>&1; then
        echo "FAIL: $kind accepted an invalid coverage mode" >&2
        exit 1
    fi
done
OS_RUN_SUITE=1 SCRIPT_DIR="$ROOT/tests/os"
source "$SCRIPT_DIR/phases/stack.sh"
unset PITHEAD_OS_MONERO_NODE_HOST PITHEAD_OS_MONERO_RPC_PORT PITHEAD_OS_MONERO_ZMQ_PORT
it_warn() { :; }
info() { :; }
PITHEAD_REQUIRE_COMPLETE=1
IT_SKIPPED_MISSING=0
phase_stack
[ "$IT_SKIPPED_MISSING" -eq 1 ]
if it_required_coverage_ok >/dev/null 2>&1; then
    echo 'FAIL: stack missing-input phase returned a complete verdict' >&2
    exit 1
fi
PITHEAD_OS_MONERO_NODE_HOST=node.example PITHEAD_OS_MONERO_RPC_PORT=18081 PITHEAD_OS_MONERO_ZMQ_PORT=18083
IT_SKIPPED_MISSING=0
_build_image() { printf fixture; }
_provision_remote_node_coordinator() { [ "$2" = node.example ]; }
_stack_container_restart_leg() { :; }
_stack_run_integration() { :; }
phase_stack
it_required_coverage_ok
RIG_BRANCH=$(sed -n '/^    local rn_mh=/,/^    fi$/p' "$SCRIPT_DIR/phases/rig.sh")
[ -n "$RIG_BRANCH" ]
rig_input_verdict() (
    local img=fixture ip=fixture
    rig_share_leg() { [ "$2" = node.example ]; }
    IT_SKIPPED_MISSING=0
    if [ "$1" = missing ]; then unset PITHEAD_OS_MONERO_NODE_HOST; fi
    eval "$RIG_BRANCH"
    it_required_coverage_ok
)
if rig_input_verdict missing >/dev/null 2>&1; then
    echo 'FAIL: rig missing-input leg returned a complete verdict' >&2
    exit 1
fi
rig_input_verdict complete
printf 'required-coverage selftest: PASS\n'
