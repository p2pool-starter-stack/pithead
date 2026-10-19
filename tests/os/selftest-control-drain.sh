#!/usr/bin/env bash
# The control spool must drain before a reboot or update proceeds.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_RUN_SUITE=1
SERIAL=$(mktemp)
# shellcheck source=tests/os/lib/core.sh
source "$HERE/lib/core.sh"
trap 'rm -f "$SERIAL" "$SERIAL.failed"' EXIT
# #2094: an unreadable or nonempty spool must fail within its deadline, never reach apply.
(
    info() { :; }
    _ssh() { printf '0\n'; }
    _control_requests_drained 5 || exit 1
    _ssh() { printf '2\n'; }
    ! _control_requests_drained 1 || exit 1
    _ssh() { return 1; }
    ! _control_requests_drained 1 || exit 1
) || exit 1
echo "control-drain: PASS"
