#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/live-upgrade-support.sh
source "$HERE/lib/live-upgrade-support.sh"
baseline=$'dashboard\t/data\t/shared/dashboard\tbind\ndashboard\t/clearnet-state\t/old/data/clearnet-state\tbind'
stable=$'dashboard\t/data\t/shared/dashboard\tbind\ndashboard\t/clearnet-state\t/shared/clearnet-state\tbind'
assert_eq "mount comparison permits migration to the unchanged chain root" \
    "$(normalized_stateful_mounts /old "$baseline" /shared)" "$(normalized_stateful_mounts /new "$stable" /shared)"
if normalized_stateful_mounts /new "$stable" /other >/dev/null 2>&1; then
    it_fail "mount comparison accepts an unexpected chain-state root"
else
    it_pass "mount comparison rejects an unexpected chain-state root"
fi
[ "$IT_FAIL" = 0 ]
