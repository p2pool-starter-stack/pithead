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
lifecycle_mining_row() { rows+="$1:$2;"; }
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
