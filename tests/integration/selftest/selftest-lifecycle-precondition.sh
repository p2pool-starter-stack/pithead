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
rx() {
    [ "${GUARD_RX_FAIL:-0}" = 0 ] || return 1
    printf '%s\n' "${GUARD_LOG:-}"
}
redact() { cat; }
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
[[ "$row_detail" == *'unreadable after 12s'* && "$row_detail" != *guard* ]]
printf '%s\n' 'PASS: the failure row carries the bound and no guard claim when the dashboard logged none'
rows='' ran=0 FAIL_READS=40
: >"$work/reads"
unset BOUND_PRECONDITION
start=$SECONDS
lifecycle_mining_step restart step
[ "$ran" = 1 ] && [ -z "$rows" ] && [ $((SECONDS - start)) -ge 200 ]
printf '%s\n' 'PASS: a proxy held down for 200 s by the mining guard is waited out by the default bound'
: >"$work/reads"
rows='' ran=0 FAIL_READS=999 BOUND_PRECONDITION=12 GUARD_LOG=$'noise\nWARNING Mining work is not valid (P2Pool reports monerod is not synchronized) — stopping xmrig-proxy\nmore noise'
if lifecycle_mining_step restart step; then exit 1; fi
[ "$ran" = 0 ] && [ "$rows" = 'fail:restart mining precondition;' ]
[[ "$row_detail" == *'unreadable after 12s'* && "$row_detail" == *'mining guard was active (#4046)'* && "$row_detail" == *'monerod is not synchronized'* ]]
printf '%s\n' 'PASS: the failure row carries the bound and names the guard when the dashboard logged it'
: >"$work/reads"
rows='' ran=0 GUARD_RX_FAIL=1
if lifecycle_mining_step restart step; then exit 1; fi
[[ "$row_detail" == *'dashboard log was unreadable'* && "$row_detail" != *'was active'* ]]
printf '%s\n' 'PASS: an unreadable dashboard log is reported as unknown, not as no guard'
