#!/usr/bin/env bash
# Run only by e2e.sh under its deploying reservation, before the binding pre-gate.
set -euo pipefail
root=$(pwd -P)
probe=$root/tests/integration/diagnostics/wallet-progress
rev=$(git rev-parse HEAD)
[[ "$rev" =~ ^[0-9a-f]{40}$ ]] || exit 1
: "${TMPDIR:?runner scratch required}"
scratch=$(mktemp -d "$TMPDIR/wallet-progress.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
token=${scratch##*.}
base_tag="pithead-wallet-probe-base:$rev-$token"
image="pithead-wallet-probe:$rev-$token"
mkdir -p results
case "${1:-}" in
prepare)
    # Compile before branch deployment; the independent source stage does not use
    # the final runtime-image argument, so the later assembly reuses its cache.
    timeout 3600 docker build --target probe-build \
        -t "pithead-wallet-probe-source:$rev" "$probe"
    exit 0
    ;;
build)
    spec=$(docker compose config --format json)
    base=$(jq -er '.services["wallet-rpc"].image' <<<"$spec")
    base_id=$(docker image inspect --format '{{.Id}}' "$base")
    docker tag "$base_id" "$base_tag"
    # Refuse a long rebuild that would grant the ordinary wallet extra catch-up time.
    timeout 300 docker build --build-arg RUNTIME_REPOSITORY=pithead-wallet-probe-base \
        --build-arg "RUNTIME_TAG=$rev-$token" \
        --label "org.pithead.wallet-probe.base=$base_id" -t "$image" "$probe"
    printf '%s\n' "$image" >results/wallet-progress-image.txt
    exit 0
    ;;
activate)
    IFS= read -r image <results/wallet-progress-image.txt
    [[ "$image" =~ ^pithead-wallet-probe:$rev-[A-Za-z0-9]+$ ]] || exit 1
    base_id=$(docker image inspect --format '{{index .Config.Labels "org.pithead.wallet-probe.base"}}' "$image")
    [[ "$base_id" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
    ;;
*) exit 2 ;;
esac
binary=$(docker run --rm --entrypoint sha256sum "$image" /usr/local/bin/monero-wallet-rpc | cut -d' ' -f1)
[[ "$binary" =~ ^[0-9a-f]{64}$ ]] || exit 1
printf 'services:\n  wallet-rpc:\n    image: %s\n' "$image" >"$scratch/override.yml"
# Explicit override only: ordinary apply/scenario commands must never inherit the probe.
docker compose -f docker-compose.yml -f "$scratch/override.yml" up -d --no-build --no-deps wallet-rpc
running=$(docker inspect --format '{{.Image}}' wallet-rpc)
expected=$(docker image inspect --format '{{.Id}}' "$image")
test "$running" = "$expected"
{
    printf 'pithead_revision=%s\nmonero_source=4f92268d7c16741cfb41e5bbe2aa46cc260a9ea5\n' "$rev"
    printf 'base_image_id=%s\nrunning_image_id=%s\nbinary_sha256=%s\n' "$base_id" "$running" "$binary"
    printf 'patch_sha256=%s\n' "$(sha256sum "$probe/numeric-progress.patch" | cut -d' ' -f1)"
    printf 'header_sha256=%s\n' "$(sha256sum "$probe/numeric-progress.h" | cut -d' ' -f1)"
} | tee results/wallet-progress-provenance.txt
