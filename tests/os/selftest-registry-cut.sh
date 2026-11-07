#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export OS_RUN_SUITE=1
source "$ROOT/tests/os/registry-cut-leg.sh"
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
check() { # <registry> <expected endpoint, or - for none>
    local got
    got=$(PITHEAD_REGISTRY="$1" registry_cut_endpoint || echo -)
    [ "$got" = "$2" ] || fail "registry '$1' gave '$got', wanted '$2'"
}
check "bench.example:5000" "bench.example 5000"
check "bench.example:5000/pithead" "bench.example 5000"
check "10.0.2.2:5443" "10.0.2.2 5443"
check "registry.example" "registry.example 443"
check "" -
check "ghcr.io/p2pool-starter-stack" -
check "ghcr.io:443" -
check 'bad host;rm:5000' -
check 'bench.example:50x0' -
echo 'selftest-registry-cut: PASS'
