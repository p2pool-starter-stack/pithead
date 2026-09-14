#!/usr/bin/env bash
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$SELF/.."
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/live-gates.sh
source "$HERE/lib/live-gates.sh"

echo "== image upgrade separates bundle trust, image trust, and registries =="
same_registry=$'tor registry.test/pithead-tor:v2@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\ndashboard registry.test/pithead-dashboard:v2@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
mixed_registry=${same_registry/registry.test\/pithead-dashboard/two.test\/pithead-dashboard}
[ "$(first_party_registry "$same_registry")" = registry.test ]
! first_party_registry "$mixed_registry" >/dev/null
BASELINE_CONFIG='{"monero":{"mode":"remote"}}'
[ "$(first_party_running_services | tr '\n' ' ')" = "tor p2pool xmrig-proxy dashboard " ]

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
UPGRADE_IMAGE_TRUSTED_KEY="$td/image.pub"
: >"$UPGRADE_IMAGE_TRUSTED_KEY"
ensure_cosign_image() { :; }
docker() { printf '%s\n' "$*" >"$td/docker"; }
run_trusted_image_cosign verify --key /trusted.pub "image@sha256:$(printf 'a%.0s' {1..64})"
grep -Fq -- "$UPGRADE_IMAGE_TRUSTED_KEY:/trusted.pub:ro" "$td/docker"

echo "selftest-live-upgrade-trust: PASS"
