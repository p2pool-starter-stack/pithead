#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
for tool in mawk gawk busybox; do command -v "$tool" >/dev/null; done
mawk -W version 2>&1 | grep -Fx 'mawk 1.3.4 20200120'

# shellcheck source=tests/stack/lib.sh
source "$ROOT/tests/stack/lib.sh"

echo "== container bridge awk portability =="
for bridge_awk in mawk gawk busybox; do
    echo "== container bridges with $bridge_awk =="
    awk() {
        if [ "$bridge_awk" = busybox ]; then command busybox awk "$@"; else command "$bridge_awk" "$@"; fi
    }
    ip() {
        printf '%s\n' \
            '1: br-0123456789ab inet 192.0.2.1/24' \
            '2: br-abcdefabcdef inet6 fd00::1/64' \
            '3: br-0123456789a inet 192.0.2.3/24' \
            '4: br-0123456789abc inet 192.0.2.4/24' \
            '5: br-0123456789ag inet 192.0.2.5/24' \
            '6: br0 inet 192.0.2.6/24' \
            '7: br-lan inet 192.0.2.7/24' \
            '8: docker0 inet 192.0.2.8/24' \
            '9: podman2 inet 192.0.2.9/24' \
            '10: vethabc123 inet 192.0.2.10/24' \
            '11: cni-podman0 inet 192.0.2.11/24' \
            '12: cni0 inet 192.0.2.12/24'
    }
    addresses="$(run_sourced "$SANDBOX" container_bridge_addrs)"
    assert_eq "$bridge_awk matches engine interfaces and preserves LAN bridges and near misses" \
        "$addresses" $'192.0.2.1\nfd00::1\n192.0.2.8\n192.0.2.9\n192.0.2.10\n192.0.2.11\n192.0.2.12'
    # shellcheck source=tests/stack/dashboard/test-dashboard-bridge-bind.sh
    source "$ROOT/tests/stack/dashboard/test-dashboard-bridge-bind.sh"
done
printf 'Bridge awk: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -eq 44 ] && [ "$FAIL" -eq 0 ]
