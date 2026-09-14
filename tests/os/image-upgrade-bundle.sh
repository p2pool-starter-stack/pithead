#!/usr/bin/env bash
# Build a signed, digest-pinned candidate bundle for the disposable KVM upgrade gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:?usage: image-upgrade-bundle.sh OUT COMMIT BUNDLE_KEY}"
COMMIT="${2:?usage: image-upgrade-bundle.sh OUT COMMIT BUNDLE_KEY}"
KEY="${3:?usage: image-upgrade-bundle.sh OUT COMMIT BUNDLE_KEY}"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
    echo "commit must be 40 lowercase hex" >&2
    exit 2
}
[[ "${PITHEAD_REGISTRY:-}" =~ ^[A-Za-z0-9._:/-]+$ ]] || {
    echo "PITHEAD_REGISTRY is required and must be a registry path" >&2
    exit 2
}
[ -f "$KEY" ] && [ ! -L "$KEY" ] || {
    echo "bundle key input is not a regular non-symlink file" >&2
    exit 2
}

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
die() {
    printf '%s\n' "$*" >&2
    exit 1
}

make_bundle "$OUT"
mkdir "$WORKDIR/repack"
tar -xzf "$OUT" -C "$WORKDIR/repack"
awk -v registry="$REGISTRY" '{gsub(/\$\{PITHEAD_REGISTRY:-ghcr.io\/p2pool-starter-stack\}/,registry); print}' \
    "$WORKDIR/repack/pithead/docker-compose.yml" >"$WORKDIR/repack/pithead/docker-compose.yml.new"
mv "$WORKDIR/repack/pithead/docker-compose.yml.new" "$WORKDIR/repack/pithead/docker-compose.yml"
tar --no-xattrs -czf "$OUT" -C "$WORKDIR/repack" pithead
cosign sign-blob --yes --tlog-upload=false --key "$KEY" --output-signature "$OUT.sig" "$OUT"
