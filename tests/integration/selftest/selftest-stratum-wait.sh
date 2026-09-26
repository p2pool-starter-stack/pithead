#!/usr/bin/env bash
#
# Self-test for _pred_stratum_hashes (#2750): the scenario's mining wait must hold until the
# proxy's live worker count reaches EXPECTED_WORKERS, not only until p2pool's cumulative
# total_hashes is non-zero. That count survives an xmrig-proxy restart, so a wait on it alone
# returned on its first poll while the rig was still on its failover pool.
#
# Standalone (not sourced by selftest.sh) so it never touches selftest.sh's file-budget ceiling.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

rx() { printf '%s' "$FIXTURE"; }
BAD=0
case_() { # name want(0=true,1=false) fixture
    local got=0
    FIXTURE="$3"
    _pred_stratum_hashes || got=1
    if [ "$got" = "$2" ]; then it_pass "$1"; else
        it_fail "$1" "predicate returned $got, want $2"
        BAD=$((BAD + 1))
    fi
}

EXPECTED_WORKERS=2
case_ "workers and hashes present -> ready" 0 '{"proxy_workers":2,"stratum":{"total_hashes":12345}}'
case_ "rig still on failover: hashes survive, workers 0 -> wait" 1 '{"proxy_workers":0,"stratum":{"total_hashes":12345}}'
case_ "fewer workers than expected -> wait" 1 '{"proxy_workers":1,"stratum":{"total_hashes":12345}}'
case_ "workers back, no hashes yet -> wait" 1 '{"proxy_workers":2,"stratum":{"total_hashes":0}}'
case_ "empty /api/state -> wait" 1 ''
unset EXPECTED_WORKERS
case_ "EXPECTED_WORKERS unset defaults to 1" 0 '{"proxy_workers":1,"stratum":{"total_hashes":1}}'

printf '\n%s: %d bad\n' "$([ "$BAD" -eq 0 ] && echo PASS || echo FAIL)" "$BAD"
[ "$BAD" -eq 0 ]
