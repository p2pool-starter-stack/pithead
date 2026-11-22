#!/usr/bin/env bash
set -euo pipefail
echo "== lifecycle mining precondition read retries within its bound =="
INTEGRATION_RUN_SUITE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=tests/integration/lib/run-lifecycle-miners.sh
source "$ROOT/tests/integration/lib/run-lifecycle-miners.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/lifecycle-precondition.XXXXXX")
trap 'rm -f "$work/reads"; rmdir "$work"' EXIT
ran=0 rows='' LIFECYCLE_MINER_STOPPED=0 FAIL_READS=1
lifecycle_mining_load() { :; }
lifecycle_mining_save() { :; }
lifecycle_mining_diagnostics() { :; }
lifecycle_miners_returned() { :; }
lifecycle_proxy_started() { echo old; }
lifecycle_worker_set() {
    echo >>"$work/reads"
    [ "$(wc -l <"$work/reads")" -gt "$FAIL_READS" ] && printf '["local"]'
}
lifecycle_mining_row() {
    rows+="$1:$2;"
    row_detail=$3
}
lifecycle_proxy_guard_held() { [ "${GUARD:-0}" = 1 ]; }
sleep() { SECONDS=$((SECONDS + $1)); }
step() { ran=$((ran + 1)); }
lifecycle_mining_step restart step
[ "$(wc -l <"$work/reads")" = 2 ] && [ "$ran" = 1 ] && [ -z "$rows" ]
printf '%s\n' 'PASS: a precondition read that fails once is retried and the step runs'
: >"$work/reads"
ran=0 FAIL_READS=999 BOUND_PRECONDITION=12
if lifecycle_mining_step restart step; then exit 1; fi
[ "$ran" = 0 ] && [ "$rows" = 'fail:restart mining precondition;' ] && [ "$(wc -l <"$work/reads")" -le 4 ]
printf '%s\n' 'PASS: a precondition read that keeps failing ends in the original fail row after the bound'
: >"$work/reads"
ran=0 rows='' FAIL_READS=40 BOUND_PRECONDITION=''
unset BOUND_PRECONDITION
lifecycle_mining_step restart step
[ "$ran" = 1 ] && [ -z "$rows" ]
printf '%s\n' 'PASS: a proxy held stopped for 200 s by the #4046 guard is waited out under the default bound'
: >"$work/reads"
ran=0 FAIL_READS=999 GUARD=1 row_detail=''
if lifecycle_mining_step restart step; then exit 1; fi
[ "$ran" = 0 ] && [ "$rows" = 'fail:restart mining precondition;' ] && [[ "$row_detail" == *'#4046'* && "$row_detail" == *'420s'* ]]
printf '%s\n' 'PASS: a proxy that never returns still fails, naming the guard and the bound'
: >"$work/reads"
rows='' ran=0 GUARD=0 row_detail=''
if lifecycle_mining_step restart step; then exit 1; fi
[[ "$row_detail" == *'420s'* && "$row_detail" != *'#4046'* ]]
printf '%s\n' 'PASS: without a guard hold the failure text does not blame the guard'
grep -q 'carry_epoch="$(rx '"'"'echo $(($(date +%s) - 120))'"'"')"' "$ROOT/tests/integration/lib/run-lifecycle.sh"
printf '%s\n' 'PASS: the carry row captures its epoch 120 s back so shares landing during the move stay outside the compared set'
