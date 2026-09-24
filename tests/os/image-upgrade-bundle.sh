#!/usr/bin/env bash
# Build a signed, digest-pinned candidate bundle for the disposable KVM upgrade gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:?usage: image-upgrade-bundle.sh OUT COMMIT BUNDLE_KEY IMAGE_PUB}"
COMMIT="${2:?usage: image-upgrade-bundle.sh OUT COMMIT BUNDLE_KEY IMAGE_PUB}"
KEY="${3:?usage: image-upgrade-bundle.sh OUT COMMIT BUNDLE_KEY IMAGE_PUB}"
IMAGE_PUB="${4:?usage: image-upgrade-bundle.sh OUT COMMIT BUNDLE_KEY IMAGE_PUB}"
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
[ -f "$IMAGE_PUB" ] && [ ! -L "$IMAGE_PUB" ] || {
    echo "image public key input is not a regular non-symlink file" >&2
    exit 2
}

cd "$ROOT"
source scripts/release/bundle.sh
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TAG="$(tr -d '[:space:]' <VERSION)"
REPO_ROOT="$ROOT"
REGISTRY="$PITHEAD_REGISTRY"
IMAGE_PREFIX="${PITHEAD_IMAGE_PREFIX:-pithead-}"
IMAGES=(tor monero p2pool xmrig-proxy dashboard)
DRY_RUN=0
GIT_COMMIT="$COMMIT"
COSIGN_ENABLED=1
source "$ROOT/tests/os/lib/input-failure.sh"
input_failure() { image_upgrade_input_failure "$@"; }
image_for() { printf '%s/%s%s' "$REGISTRY" "$IMAGE_PREFIX" "$1"; }
is_digest_ref_for() { [[ "$1" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] && [ "${1%@*}" = "$2" ]; }
get_digest() {
    local ref rc
    ref="$(image_for "$1"):v$TAG"
    docker pull -q "$ref" >/dev/null 2>&1 || {
        rc=$?
        input_failure tag-or-digest-resolution 'docker pull <candidate-tag>' "$rc"
        return "$rc"
    }
    docker image inspect --format '{{index .RepoDigests 0}}' "$ref" 2>/dev/null || {
        rc=$?
        input_failure tag-or-digest-resolution 'docker image inspect <candidate-tag>' "$rc"
        return "$rc"
    }
}
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
die() {
    input_failure candidate-bundle 'make_bundle <candidate>' 1 || true
    exit 1
}

make_bundle "$OUT"
mkdir "$WORKDIR/repack" >/dev/null 2>&1 || {
    rc=$?
    input_failure candidate-bundle 'mkdir <candidate-repack>' "$rc" || true
    exit "$rc"
}
tar -xzf "$OUT" -C "$WORKDIR/repack" >/dev/null 2>&1 || {
    rc=$?
    input_failure candidate-bundle 'tar -xzf <candidate-bundle>' "$rc" || true
    exit "$rc"
}
# REGISTRY is limited to [A-Za-z0-9._:/-] above, so `|` cannot appear in it.
sed -i "s|\${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}|$REGISTRY|g" \
    "$WORKDIR/repack/pithead/docker-compose.yml" >/dev/null 2>&1 || {
    rc=$?
    input_failure candidate-bundle 'sed -i <candidate-compose> <registry-rewrite>' "$rc" || true
    exit "$rc"
}
cp "$IMAGE_PUB" "$WORKDIR/repack/pithead/cosign.pub" >/dev/null 2>&1 || {
    rc=$?
    input_failure candidate-bundle 'cp <image-public-key> <candidate-cosign-public-key>' "$rc" || true
    exit "$rc"
}
tar --no-xattrs -czf "$OUT" -C "$WORKDIR/repack" pithead >/dev/null 2>&1 || {
    rc=$?
    input_failure candidate-bundle 'tar -czf <candidate-bundle>' "$rc" || true
    exit "$rc"
}
cosign sign-blob --yes --use-signing-config=false --new-bundle-format=false --tlog-upload=false --key "$KEY" \
    --output-signature "$OUT.sig" "$OUT" >/dev/null 2>&1 || {
    rc=$?
    input_failure signing 'cosign sign-blob <candidate> with <bundle-key>' "$rc"
    exit "$rc"
}
