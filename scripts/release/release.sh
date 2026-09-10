#!/usr/bin/env bash
#
# Pithead release pipeline (#44) — run from the private build/test server.
#
# Implements the documented stage -> smoke-test -> promote-by-digest flow (docs/dev/releasing.md):
#
#   1. Preflight      clean tree, read VERSION, ensure the tag isn't already released, resolve pins
#   2. Test gate      `make test` (+ the #54 integration matrix, unless skipped) — blocking
#   3. Build          build the 5 first-party images with OCI labels + the release version baked in
#   4. Stage          push to a staging tag (:vX.Y.Z-rc.N) on GHCR and capture immutable digests
#   5. Smoke          pull the STAGED images back and verify they resolve to the right version
#   6. Promote        re-tag the smoke-tested digests to :vX.Y.Z + :latest (no rebuild) and push
#   6b. Sign          cosign-sign the promoted digests + the install bundle with the box's key (#376)
#   7. Publish        git tag, GitHub Release from CHANGELOG + assets, fast-forward main to the tag
#
# Nothing user-facing is published until every gate is green. Promotion is by digest, so the released
# bundle is bit-for-bit what was smoke-tested. The script NEVER starts the live stack on this host and
# never prints a registry token.
#
# Usage:
#   scripts/release/release.sh [options]              (or: make release ARGS="...")
#
# Options:
#   --dry-run            Build the local CLI, run preflight, and print the plan. No image build/push/publish.
#   --rc N               Staging release-candidate number (default: 1) -> :vX.Y.Z-rc.N.
#   --skip-tests         Skip `make test` (NOT recommended; the gate is what makes a release trustworthy).
#   --skip-integration   Skip the #54 live integration matrix (still runs `make test`).
#   --skip-smoke         Skip the staged-image smoke verification.
#   --draft              Create the GitHub Release as a DRAFT (held for review; publish it by hand).
#   --resume-promote     Skip build/stage; promote the already-staged digests (retry after a smoke pass).
#   --allow-dirty        Don't require a clean git working tree (for local experimentation only).
#   --unsigned           Publish WITHOUT cosign signatures. One-click upgrades refuse an unsigned
#                        release once cosign.pub is committed — deliberate, loud, and rarely right.
#   -y, --yes            Don't prompt before the irreversible steps (push, tag, publish).
#   -h, --help           Show this help.
#
# Environment:
#   PITHEAD_REGISTRY        Registry namespace (default: ghcr.io/p2pool-starter-stack).
#   PITHEAD_IMAGE_PREFIX    Image-name prefix (default: pithead-) -> ghcr.io/.../pithead-dashboard.
#   GHCR_USER / GHCR_TOKEN  Registry login. Token falls back to GITHUB_TOKEN, then `gh auth token`.
#   RELEASE_INTEGRATION_ARGS  Extra args passed to `make test-integration ARGS=...` (the #54 gate).
#   RELEASE_SMOKE_CMD       Optional command run during the smoke stage for a fuller functional check.
#   COSIGN_KEY / COSIGN_PASSWORD  Release signing (#376): path to the cosign private key on this box
#                           and its passphrase. Promoted digests + the bundle get key signatures;
#                           the committed cosign.pub (repo root, shipped in the bundle) verifies them.
#                           Required — preflight refuses the cut without them (#960).
#
set -euo pipefail

# --- Configuration -------------------------------------------------------------------------------

REGISTRY="${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}"
IMAGE_PREFIX="${PITHEAD_IMAGE_PREFIX:-pithead-}"

# The 5 first-party images, by build-dir / image-name suffix (build context = "build/<suffix>",
# published image = "$REGISTRY/${IMAGE_PREFIX}<suffix>"). The compose service for "monero" is "monerod". dashboard is the one exception — build context "dashboard/" at the repo root (#1106) — see build_images() below.
IMAGES=(tor monero p2pool xmrig-proxy dashboard)

# Target platform(s) for the published images. linux/amd64 ONLY: the bundled binaries are x86_64
# (monero/p2pool/xmrig-proxy ship `linux-x64`, and xmrig-proxy has NO arm64 build at all — so an arm64
# image can't be made to work), and self-hosted miners run x86_64. The point of buildx here is to FORCE
# amd64 even on an arm64 release host — a plain `docker build` on Apple Silicon labels the image arm64
# (the v1.0.0 bug), so it never ran on x86_64. The smoke stage fails the release if a pushed image
# doesn't carry every platform listed here. (Overridable via PITHEAD_PLATFORMS, but the components must
# actually ship binaries for any arch you add.)
PLATFORMS="${PITHEAD_PLATFORMS:-linux/amd64}"
BUILDX_BUILDER="${PITHEAD_BUILDX_BUILDER:-pithead-release}"

SOURCE_URL="https://github.com/p2pool-starter-stack/pithead"

# --- Small utilities -----------------------------------------------------------------------------

C_RESET=$'\033[0m'
C_BLUE=$'\033[1;34m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_RED=$'\033[1;31m'

log() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
    printf '%s ✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}
stage() { printf '\n%s━━ %s %s\n' "$C_BLUE" "$*" "$C_RESET"; }

# In --dry-run, side-effecting commands are printed, not run. Read-only steps always run.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   %s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
        return 0
    fi
    "$@"
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    local reply
    read -r -p "$1 (y/N): " reply || true
    [[ "$reply" =~ ^[Yy] ]]
}

image_for() { printf '%s/%s%s' "$REGISTRY" "$IMAGE_PREFIX" "$1"; }

# SemVer X.Y.Z with an optional -prerelease / .build suffix (e.g. 0.1.0, 1.2.3-rc.1). No leading 'v'.
is_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]]; }

# --- Argument parsing ----------------------------------------------------------------------------

DRY_RUN=0
RC=1
SKIP_TESTS=0
SKIP_INTEGRATION=0
SKIP_SMOKE=0
RESUME_PROMOTE=0
ALLOW_DIRTY=0
ASSUME_YES=0
DRAFT=0
UNSIGNED=0

while [ $# -gt 0 ]; do
    case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --rc)
        RC="${2:?--rc needs a number}"
        shift
        ;;
    --rc=*) RC="${1#*=}" ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --skip-integration) SKIP_INTEGRATION=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    --draft) DRAFT=1 ;;
    --resume-promote) RESUME_PROMOTE=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --unsigned) UNSIGNED=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    -h | --help)
        sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

[[ "$RC" =~ ^[0-9]+$ ]] || die "--rc must be a number (got '$RC')."

# --- State (filled by the stages) ----------------------------------------------------------------

REPO_ROOT="" STACK_VERSION="" TAG="" STAGING_TAG="" GIT_COMMIT="" GIT_BRANCH="" BUILD_DATE=""
WORKDIR="" # scratch dir for digests, the manifest and the bundle (created in main, after preflight)

# Staged image digests are kept as files ($WORKDIR/digest.<suffix>), not an associative array, so this
# runs on the stock macOS bash 3.2 too and the digests survive across stages.
set_digest() { printf '%s' "$2" >"$WORKDIR/digest.$1"; }
get_digest() { cat "$WORKDIR/digest.$1" 2>/dev/null || true; }

# GHCR is read-after-push eventually-consistent: a tag it JUST accepted can fail to resolve for a few
# seconds (#429 — this killed stage-4 digest capture twice on the v1.3.1 cut). Retry a registry read up
# to $REGISTRY_READ_RETRIES times, with $REGISTRY_READ_BACKOFF-second backoff, requiring non-empty
# output. Emits the read's stdout; returns non-zero only after every attempt fails, so a genuinely-
# missing image still stops the release (the caller's `[ -n "$digest" ] || die` fires as before).
REGISTRY_READ_RETRIES="${PITHEAD_REGISTRY_READ_RETRIES:-5}"
REGISTRY_READ_BACKOFF="${PITHEAD_REGISTRY_READ_BACKOFF:-3}"

# The registry inspect, wrapped in a function so the tests can stub it (fail N times, then succeed).
buildx_inspect() { docker buildx imagetools inspect "$@"; }

retry_registry_read() {
    local attempt=1 out expected_digest="${REGISTRY_READ_EXPECT_DIGEST:-}"
    while :; do
        if out="$("$@" 2>/dev/null)" && [ -n "$out" ] &&
            { [ -z "$expected_digest" ] || grep -Fxq "Digest: $expected_digest" <<<"$out"; }; then
            printf '%s' "$out"
            return 0
        fi
        [ "$attempt" -ge "$REGISTRY_READ_RETRIES" ] && return 1
        warn "registry read failed (attempt $attempt/$REGISTRY_READ_RETRIES): $* — GHCR read-after-push lag? retrying in ${REGISTRY_READ_BACKOFF}s..."
        sleep "$REGISTRY_READ_BACKOFF"
        attempt=$((attempt + 1))
    done
}
# Parse and validate the manifest-list digest that promotion re-tags.
manifest_digest() {
    local digest
    digest="$(retry_registry_read buildx_inspect "$1" | awk '/^Digest:/{print $2; exit}')" || return 1
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$digest"
}

is_digest_ref_for() { [[ "$1" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] && [ "${1%@*}" = "$2" ]; }

# Resolve a single upstream component pin on demand (the "ingredients" each release bundles).
pin() {
    case "$1" in
    p2pool) grep -oE '^ARG P2POOL_VERSION=.*' build/p2pool/Dockerfile | cut -d= -f2 ;;
    monero) grep -oE '^ARG MONERO_VERSION=.*' build/monero/Dockerfile | cut -d= -f2 ;;
    xmrig-proxy) grep -oE '^ARG XMRIG_PROXY_VERSION=.*' build/xmrig-proxy/Dockerfile | cut -d= -f2 ;;
    tor-base) grep -oE '^FROM [^ ]+' build/tor/Dockerfile | head -1 | awk '{print $2}' ;;
    # `tari` is the NODE, deliberately, because scripts/watch/pin-watch.sh reads this arm for upstream
    # currency and both Tari images come from one upstream repo — a second row there would say the
    # same thing twice. The stack pins two images though (node + view-only console wallet), they are
    # bumped together, and the release notes have to name both or a wallet-only move reads as
    # unchanged (#1138). tests/stack/standalone/test_compose.sh asserts the two carry the same tag, so the
    # lockstep this relies on is guarded rather than assumed.
    tari) grep -oE 'quay.io/tarilabs/minotari_node:[^ ]+' docker-compose.yml | head -1 ;;
    tari-wallet) grep -oE 'quay.io/tarilabs/minotari_console_wallet:[^ ]+' docker-compose.yml | head -1 ;;
    caddy) grep -oE 'caddy:[0-9.]+@sha256:[a-f0-9]+' docker-compose.yml | head -1 ;;
    socket-proxy) grep -oE 'tecnativa/docker-socket-proxy:[^ ]+' docker-compose.yml | head -1 ;;
    esac
}

# --- Stage 1: preflight --------------------------------------------------------------------------

RELEASE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/preflight.sh
source "$RELEASE_LIB_DIR/preflight.sh"
# shellcheck source=scripts/release/images.sh
source "$RELEASE_LIB_DIR/images.sh"
# shellcheck source=scripts/release/bundle.sh
source "$RELEASE_LIB_DIR/bundle.sh"

# --- Main -----------------------------------------------------------------------------------------

main() {
    log "Pithead release pipeline (#44)$([ "$DRY_RUN" -eq 1 ] && echo '  [DRY RUN]')"
    preflight
    WORKDIR="$(mktemp -d)" # holds the captured digests, the ingredients manifest and the bundle
    if [ "$RESUME_PROMOTE" -eq 1 ]; then
        warn "--resume-promote: skipping build/stage. Re-staging to recover digests..."
        ghcr_login
        local suffix repo digest
        for suffix in "${IMAGES[@]}"; do
            repo="$(image_for "$suffix")"
            # #557: same errexit-unreachable shape as stage_push above — a bare assignment aborts
            # under errexit once retries are exhausted, before this die() fires.
            if ! digest="$(manifest_digest "$repo:$STAGING_TAG")" || [ -z "$digest" ]; then
                die "Cannot resolve a staged digest for $repo:$STAGING_TAG — stage first."
            fi
            set_digest "$suffix" "$repo@$digest"
        done
    else
        test_gate
        build_images
        stage_push
    fi
    smoke_test
    promote
    sign_images # #376 — signs the digests promote re-tagged; --resume-promote reaches this too
    publish

    printf '\n'
    ok "Release $TAG complete."
    [ "$DRY_RUN" -eq 1 ] && warn "(dry run — nothing was actually built, pushed, tagged, or published.)"
    [ -n "$WORKDIR" ] && log "Artifacts left in: $WORKDIR"
}

# Run the pipeline only when executed directly; allow sourcing for unit tests (functions only).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
