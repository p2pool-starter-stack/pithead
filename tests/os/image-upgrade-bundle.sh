#!/usr/bin/env bash
# Build a signed, digest-pinned candidate bundle for the disposable KVM upgrade gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:?usage: image-upgrade-bundle.sh OUT COMMIT BUNDLE_KEY}"
COMMIT="${2:?usage: image-upgrade-bundle.sh OUT COMMIT BUNDLE_KEY}"
KEY="${3:?usage: image-upgrade-bundle.sh OUT COMMIT BUNDLE_KEY}"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "commit must be 40 lowercase hex" >&2; exit 2; }
[ -n "${PITHEAD_REGISTRY:-}" ] || { echo "PITHEAD_REGISTRY is required" >&2; exit 2; }
[ -f "$KEY" ] || { echo "bundle key is not a regular file" >&2; exit 2; }

cd "$ROOT"
source scripts/release/bundle.sh
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TAG="$(tr -d '[:space:]' <VERSION)"
REGISTRY="$PITHEAD_REGISTRY"
IMAGE_PREFIX="${PITHEAD_IMAGE_PREFIX:-pithead-}"
IMAGES=(tor monero p2pool xmrig-proxy dashboard)
DRY_RUN=0
GIT_COMMIT="$COMMIT"
COSIGN_ENABLED=1
image_for() { printf '%s/%s%s' "$REGISTRY" "$IMAGE_PREFIX" "$1"; }
is_digest_ref_for() { [[ "$1" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] && [ "${1%@*}" = "$2" ]; }
get_digest() {
    local ref
    ref="$(image_for "$1"):v$TAG"
    docker pull -q "$ref" >/dev/null
    docker image inspect --format '{{index .RepoDigests 0}}' "$ref"
}
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }

make_bundle "$OUT"
cosign sign-blob --yes --tlog-upload=false --key "$KEY" --output-signature "$OUT.sig" "$OUT"
