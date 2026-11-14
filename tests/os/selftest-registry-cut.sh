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
pull_first='2026-11-10 01:03:15.39 +0000 UTC m=+7.2 image pull abc123 docker.io/library/caddy@sha256:aa
2026-11-10 01:03:38.16 +0000 UTC m=+0.4 image loadfromarchive abc123 /opt/pithead/images/caddy.tar.gz'
load_first='2026-11-10 01:03:02.02 +0000 UTC m=+5.0 image loadfromarchive def456 /opt/pithead/images/dashboard.tar.gz
2026-11-10 01:03:02.34 +0000 UTC m=+0.0 image pull def456 registry/pithead-dashboard:v2
2026-11-10 01:04:52.23 +0000 UTC m=+0.0 image pull 999999 ghcr.io/tari-project/minotari_node@sha256:bb'
got=$(printf '%s\n' "$pull_first" | awk "$(registry_cut_pull_filter)")
[ "$got" = "docker.io/library/caddy@sha256:aa" ] || fail "a pull before the archive load was not reported: '$got'"
got=$(printf '%s\n' "$load_first" | awk "$(registry_cut_pull_filter)")
[ -z "$got" ] || fail "a load before the pull, or a Tari pull, was reported: '$got'"
echo 'selftest-registry-cut: PASS'
