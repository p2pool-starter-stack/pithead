#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/tmp}}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:?}/marker-images.XXXXXX")
trap 'rm -rf "$T"' EXIT
export PITHEAD_BUILD_IMAGE_TEST=1
source "$ROOT/os/build-image.sh"
cd "$T"
git init -q
printf fixture >fixture
git add fixture
git -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
commit=$(git rev-parse HEAD)
marker_digest="sha256:$(printf '%064d' 2)"
config_digest=$(printf '%064d' 3)
base_digest="sha256:$(printf '%064d' 1)"
registry=registry.example/fixture
marker_ref="$registry/pithead-dashboard@$marker_digest"
manifest="$T/markers.json"
jq -n --arg commit "$commit" --arg image "$marker_ref" \
    '{version: 1, source_commit: $commit, images: {v2: $image}}' >"$manifest"
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
[ "$(select_marker_dashboard "$(cat "$manifest")" v2 "$registry")" = "$marker_ref" ] || fail 'wrong marker selected'
[ "$(PITHEAD_TEST_IMAGE_COMMIT="$commit" select_marker_dashboard "$(cat "$manifest")" v2 "$registry")" = "$marker_ref" ] || fail 'archive source commit refused'
if PITHEAD_TEST_IMAGE_COMMIT=other select_marker_dashboard "$(cat "$manifest")" v2 "$registry" >"$T/refusal.log" 2>&1; then fail 'wrong archive source commit accepted'; fi
for mutation in \
    '.version = 2' \
    '.source_commit = "other"' \
    '.images.v2 = null' \
    '.images.v2 = "registry.example/fixture/pithead-dashboard:mutable"' \
    '.images.v2 |= sub("fixture"; "other")'; do
    jq "$mutation" "$manifest" >"$T/invalid.json"
    if select_marker_dashboard "$(cat "$T/invalid.json")" v2 "$registry" >"$T/refusal.log" 2>&1; then fail "accepted $mutation"; fi
done
if select_marker_dashboard "$(cat "$manifest")" unknown "$registry" >"$T/refusal.log" 2>&1; then fail 'unknown marker accepted'; fi
if select_marker_dashboard "" v2 "$registry" >"$T/refusal.log" 2>&1; then fail 'missing mapping accepted'; fi
for invalid_mapping in '{' '[]' 'null' '"not an object"' "$manifest"; do
    if select_marker_dashboard "$invalid_mapping" v2 "$registry" >"$T/refusal.log" 2>&1; then fail 'invalid JSON mapping accepted'; fi
done
mkdir -p os/build/stage images
for service in tor monero p2pool xmrig-proxy dashboard; do
    printf '  %s:\n    image: registry.example/fixture/pithead-%s:v2\n' "$service" "$service"
done >os/build/stage/docker-compose.yml
printf '[{"Config":"%s.json"}]\n' "$config_digest" >images/manifest.json
tar -cf "$T/marker.tar" -C images manifest.json
FAKE_SELECTED=""
docker() {
    printf '%s\n' "$*" >>"$T/docker.calls"
    case "$*" in
    'buildx imagetools inspect '*) printf 'Digest: %s\n' "$base_digest" ;;
    "pull -q $marker_ref") : ;;
    "tag $marker_ref "*) FAKE_SELECTED="$2" ;;
    'save '*)
        [ "$FAKE_SELECTED" = "$marker_ref" ] || return 1
        cat "$T/marker.tar"
        ;;
    *) return 1 ;;
    esac
}
STACK_VERSION=v2
awk '/^if \[ "\$\{PITHEAD_OS_SYNTHETIC_COMPOSE:-\}" != 1 \]; then$/ { copying=1 }
    copying { print }
    copying && /^fi$/ { exit }' "$ROOT/os/build-image.sh" >"$T/default-pin.sh"
(
    unset MARKER_DASHBOARD_IMAGE
    source "$T/default-pin.sh"
)
grep -qF "pithead-dashboard:v2@$base_digest" os/build/stage/docker-compose.yml || fail 'default dashboard pin changed'
PITHEAD_TEST_MARKER_IMAGES=$(cat "$manifest")
export PITHEAD_TEST_MARKER=v2 PITHEAD_TEST_MARKER_IMAGES PITHEAD_TEST_SSH_PUBKEY=fixture
export PITHEAD_REGISTRY="$registry"
STACK_VERSION=v2
WIZARD_IMAGE="$registry/pithead-dashboard:v2"
WIZARD_SOURCE="$WIZARD_IMAGE"
sed -n '/^MARKER_DASHBOARD_IMAGE=""$/,/^if \[ -n "${PITHEAD_TEST_BREAK_HEALTHCHECK:-}" \]; then$/p' "$ROOT/os/build-image.sh" |
    sed '$d' >"$T/pin.sh"
[ -s "$T/pin.sh" ] || fail 'marker selection and pinning stanza missing'
source "$T/pin.sh"
grep -qF "pithead-dashboard:v2@$marker_digest" os/build/stage/docker-compose.yml || fail 'Compose did not pin final marker'
grep -qF "pithead-tor:v2@$base_digest" os/build/stage/docker-compose.yml || fail 'base service pin changed'
sed -n '/^if \[ -n "${PITHEAD_WIZARD_IMAGE:-}" \]; then$/,/^docker save /p' "$ROOT/os/build-image.sh" >"$T/archive.sh"
[ -s "$T/archive.sh" ] || fail 'wizard archive stanza missing'
mkdir -p os/rootfs/images
source "$T/archive.sh"
archive_config=$(tar -xzOf os/rootfs/images/dashboard.tar.gz manifest.json | jq -r '.[0].Config')
[ "$archive_config" = "$config_digest.json" ] || fail 'archive does not contain selected signed marker image'
[ "$FAKE_SELECTED" = "$marker_ref" ] || fail 'archive source differs from pinned source'
if grep -q '^build ' "$T/docker.calls"; then fail 'builder added an unsigned image layer'; fi
python3 - "$ROOT" <<'PYTHON'
from pathlib import Path
import json
import re
import sys

root = Path(sys.argv[1])
declared = set(json.loads((root / "tests/os/dashboard-markers.json").read_text()))
for script in (root / "tests/os").rglob("*.sh"):
    if script.name.startswith("selftest"):
        continue
    code = "\n".join(line for line in script.read_text().splitlines() if not line.lstrip().startswith("#"))
    for marker in re.findall(r"\b_build_(?:image|bundle)(?:_stamped)?\s+([a-zA-Z0-9][a-zA-Z0-9._-]*)", code):
        if marker not in declared:
            raise SystemExit(f"undeclared dashboard marker: {marker} in {script.name}")
PYTHON
echo 'selftest-marker-images: PASS'
