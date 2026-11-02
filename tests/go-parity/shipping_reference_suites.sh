#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$ROOT/tests/stack/lib.sh"
for fragment in \
    release/test-release.sh \
    release/test-release-rootfs-publish.sh \
    appliance/test-appliance-build-compose-source.sh; do
    # shellcheck disable=SC1090
    source "$ROOT/tests/stack/$fragment"
done
printf 'shipping reference fragments: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
