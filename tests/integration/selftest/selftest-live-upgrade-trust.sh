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
! first_party_registry "$mixed_registry" >/dev/null || exit 1

echo "== first_party_registry tolerates a container engine reporting tag@digest as a bare digest (job 1142) =="
digest_only=$'tor registry.test/pithead-tor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\ndashboard registry.test/pithead-dashboard@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
[ "$(first_party_registry "$digest_only")" = registry.test ]
mixed_tagging=$'tor registry.test/pithead-tor@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\ndashboard registry.test/pithead-dashboard:v2@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
[ "$(first_party_registry "$mixed_tagging")" = registry.test ]
BASELINE_CONFIG='{"monero":{"mode":"remote"}}'
[ "$(first_party_running_services | tr '\n' ' ')" = "tor p2pool xmrig-proxy dashboard " ]
UPGRADE_CANDIDATE_ALL_REFS=$'tor registry.test/pithead-tor:v2@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nmonerod registry.test/pithead-monero:v2@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\np2pool registry.test/pithead-p2pool:v2@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\nxmrig-proxy registry.test/pithead-xmrig-proxy:v2@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\ndashboard registry.test/pithead-dashboard:v2@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
remote_candidate_refs="$(candidate_refs_for_running_set "$(first_party_running_services)")"
[ "$(printf '%s\n' "$remote_candidate_refs" | cut -d' ' -f1 | tr '\n' ' ')" = "tor p2pool xmrig-proxy dashboard " ]
pinned_refs_valid "$remote_candidate_refs" "$(first_party_running_services)"

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
UPGRADE_IMAGE_TRUSTED_KEY="$td/image.pub"
: >"$UPGRADE_IMAGE_TRUSTED_KEY"
ensure_cosign_image() { :; }
docker() { printf '%s\n' "$*" >"$td/docker"; }
run_trusted_image_cosign verify --key /trusted.pub "image@sha256:$(printf 'a%.0s' {1..64})"
grep -Fq -- "$UPGRADE_IMAGE_TRUSTED_KEY:/trusted.pub:ro" "$td/docker"
! grep -Eq -- '--registry-cacert|--allow-http-registry' "$td/docker" || exit 1

echo "== image verification trusts the candidate's registry the way verify_release_images does =="
digest_ref="image@sha256:$(printf 'a%.0s' {1..64})"
UPGRADE_STAGE_DIR="$td/stage"
UPGRADE_CANDIDATE_REGISTRY=registry.test
mkdir -p "$UPGRADE_STAGE_DIR/pithead"
: >"$UPGRADE_STAGE_DIR/pithead/cosign.registry-ca.crt"
run_trusted_image_cosign verify --key /trusted.pub "$digest_ref"
grep -Fq -- "$UPGRADE_STAGE_DIR/pithead/cosign.registry-ca.crt:/registry-ca.crt:ro" "$td/docker"
grep -Fq -- "$digest_ref --registry-cacert /registry-ca.crt" "$td/docker"
rm "$UPGRADE_STAGE_DIR/pithead/cosign.registry-ca.crt"
printf 'debug\n' >"$td/variant"
PITHEAD_VARIANT_FILE="$td/variant" run_trusted_image_cosign verify --key /trusted.pub "$digest_ref"
grep -Fq -- "$digest_ref --allow-http-registry" "$td/docker"
printf 'release\n' >"$td/variant"
PITHEAD_VARIANT_FILE="$td/variant" run_trusted_image_cosign verify --key /trusted.pub "$digest_ref"
! grep -Fq -- '--allow-http-registry' "$td/docker" || exit 1
UPGRADE_CANDIDATE_REGISTRY=ghcr.io/p2pool-starter-stack
printf 'debug\n' >"$td/variant"
PITHEAD_VARIANT_FILE="$td/variant" run_trusted_image_cosign verify --key /trusted.pub "$digest_ref"
! grep -Fq -- '--allow-http-registry' "$td/docker" || exit 1

echo "== a refused candidate names the trust sub-step it stopped at =="
for input in bundle sig bundle.pub image.pub; do : >"$td/$input"; done
CANDIDATE_BUNDLE="$td/bundle" CANDIDATE_SIGNATURE="$td/sig"
TRUSTED_COSIGN_PUB="$td/bundle.pub" TRUSTED_IMAGE_COSIGN_PUB="$td/image.pub"
docker() { return 1; }
if TMPDIR="$td" prepare_candidate_bundle; then exit 1; fi
[ "$UPGRADE_TRUST_STEP" = bundle-signature ]

echo "== an incomplete pre-upgrade capture names each empty input, never a ref =="
d64=$(printf 'a%.0s' {1..64})
first=$'tor reg.test/pithead-tor:1.20.0@sha256:'"$d64"$'\ndashboard reg.test/pithead-dashboard:1.20.0@sha256:'"$d64"
UPGRADE_CANDIDATE_ALL_REFS=$'tor x\ndashboard y\ncaddy z'
[ -z "$(upgrade_capture_gaps m 0 "$first" "$first" reg.test c c)" ]
[ "$(upgrade_capture_gaps "" 1 "$first" "$first" reg.test c c)" = "stateful-mounts(exit=1)" ]
[ "$(upgrade_capture_gaps m 0 "" "" "" "" "")" = "running-refs first-party-refs" ]
untagged=$'tor reg.test/pithead-tor@sha256:'"$d64"$'\ndashboard reg.test/pithead-dashboard:1.20.0@sha256:'"$d64"
[ -z "$(upgrade_capture_gaps m 0 "$untagged" "$untagged" reg.test c c)" ]
mixed_untagged=$'tor reg.test/pithead-tor@sha256:'"$d64"$'\ndashboard other.test/pithead-dashboard:1.20.0@sha256:'"$d64"
gaps="$(upgrade_capture_gaps m 0 "$mixed_untagged" "$mixed_untagged" "" c c)"
[ "$gaps" = "baseline-registry(dashboard:mixed-registry)" ]
! grep -Fq reg.test <<<"$gaps" || exit 1
! grep -Fq other.test <<<"$gaps" || exit 1
mixed=$'tor reg.test/pithead-tor:1@sha256:'"$d64"$'\ndashboard other.test/pithead-dashboard:1@sha256:'"$d64"$'\np2pool reg.test/pithead-tor:1'
[ "$(upgrade_capture_gaps m 0 "$mixed" "$mixed" "" c c)" = "baseline-registry(dashboard:mixed-registry,p2pool:unexpected-image)" ]
bare=$'tor pithead-tor:1@sha256:'"$d64"$'\ndashboard reg.test/pithead-dashboard:1@sha256:'"$d64"$'\np2pool reg.test/pithead-p2pool:1@sha256:'"$d64"
[ "$(upgrade_capture_gaps m 0 "$bare" "$bare" "" c c)" = "baseline-registry(tor:no-registry)" ]
running=$'tor a\ndashboard b\nwallet-rpc c\ncaddy d'
[ "$(upgrade_capture_gaps m 0 "$running" "$first" reg.test "" "")" = "candidate-first-party(missing:) candidate-all(missing:wallet-rpc)" ]

echo "selftest-live-upgrade-trust: PASS"
