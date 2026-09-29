#!/usr/bin/env bash
# The image-upgrade gate must assert the worker set its waiter actually accepted.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$SELF/.."
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/live-gates.sh
source "$HERE/lib/live-gates.sh"

echo "== image-upgrade accepted worker set =="
worker_names() { printf '%s\n' pithead; }
check_capture() {
    local accepted=unset
    if _pred_worker_set_capture another accepted; then return 1; fi
    [ "$accepted" = unset ]
    wait_for 0 0 "the exact pre-upgrade worker set" _pred_worker_set_capture pithead accepted
    worker_names() { :; } # The next dashboard poll drops the entry.
    [ "$accepted" = pithead ]
}
check_capture

gate="$(sed -n '/^run_image_upgrade() {$/,/^}$/p' "$HERE/lib/live-gates.sh")"
grep -Fq '_pred_worker_set_capture "$before_workers" after_workers' <<<"$gate"
[ "$(grep -Fc 'after_workers="$(worker_names)"' <<<"$gate")" = 1 ]
echo "image-upgrade accepted worker set: PASS"
