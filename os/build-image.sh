#!/usr/bin/env bash
# Build the pithead-os appliance rootfs (#77 phase 2): the OS as a container build, exported to a
# tarball. os/rauc/mkimage.sh turns that tarball into a bootable image and os/rauc/mkbundle.sh
# turns it into an update bundle. Run from the repo root on a box with docker.
#   os/build-image.sh [--ssh [PUBKEY_FILE]] [--fresh-index] [--stage-only]   -> os/build/pithead-root.tar
#
#   --ssh [FILE]   debug/bench variant: bake FILE (default: the builder's ~/.ssh/id_ed25519.pub,
#                  falling back to id_rsa.pub) as root's authorized key and enable sshd. Release
#                  builds omit it and stay shell-less. Sets the same PITHEAD_TEST_SSH_PUBKEY the
#                  env path always honored — the flag exists so the bench recipe is one word,
#                  not a rediscovered env var.
#   --fresh-index  bust ONLY the rootfs Dockerfile's apt-update layer (#929): a warm builder
#                  cache reuses that layer's apt index for weeks, and when the mirror rotates a
#                  package the stale index 404s on install. Later layers still cache normally.
#   --stage-only   stage os/build/stage/ (the compose file and its stamp, see stage_compose) and
#                  stop before docker: the CI rootfs scan runs the Dockerfile itself and needs
#                  exactly this step first, since the Dockerfile COPYs from that directory.
#   PITHEAD_RIGFORGE_REF=<40-hex-commit> temporarily tests an unreleased immutable RigForge tree.
# The compose file is NOT taken from the working tree when the release it names already exists:
# stage_compose below copies it from the tag STACK_VERSION resolves to, and falls back to the tree
# only while that tag does not exist yet (mid release-prep). See the function for why.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

while [ $# -gt 0 ]; do
    case "$1" in
    --ssh)
        keyfile=""
        # An optional value: `--ssh path/to/key.pub` or bare `--ssh` for the builder's own key.
        if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then
            keyfile="$2"
            shift
        else
            for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
                [ -s "$k" ] && keyfile="$k" && break
            done
        fi
        [ -s "${keyfile:-}" ] || {
            echo "--ssh: no public key found (looked for ~/.ssh/id_ed25519.pub, ~/.ssh/id_rsa.pub); pass one explicitly" >&2
            exit 1
        }
        PITHEAD_TEST_SSH_PUBKEY="$(head -n1 "$keyfile")"
        export PITHEAD_TEST_SSH_PUBKEY
        echo "==> debug build: sshd enabled, key from $keyfile"
        ;;
    --fresh-index)
        FRESH_INDEX=1
        ;;
    --stage-only)
        STAGE_ONLY=1
        ;;
    *)
        echo "unknown argument: $1 (usage: os/build-image.sh [--ssh [PUBKEY_FILE]] [--fresh-index] [--stage-only])" >&2
        exit 1
        ;;
    esac
    shift
done

# apt_fetch_failure_hint (#929): given a build log tail, detect the stale-apt-index 404 signature
# and print the remedy. Split out so it's testable without docker (tests/stack/run.sh covers it).
apt_fetch_failure_hint() {
    if grep -qE '404  Not Found|Unable to fetch some archives' <<<"$1"; then
        echo "==> looks like a stale apt index (mirror rotated a package since the last build)." >&2
        echo "==> rerun with: os/build-image.sh --fresh-index" >&2
    fi
}

rigforge_build_args=()
if [ -n "${PITHEAD_RIGFORGE_REF:-}" ]; then
    [[ "$PITHEAD_RIGFORGE_REF" =~ ^[0-9a-f]{40}$ ]] || {
        echo "PITHEAD_RIGFORGE_REF must be a full lowercase 40-hex commit" >&2
        exit 1
    }
    rigforge_build_args=(--build-arg "RIGFORGE_REF=$PITHEAD_RIGFORGE_REF")
fi

is_immutable_image_ref() { [[ "$1" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; }

# stage_compose (#1215): put the compose file the image will ship, plus a COMPOSE_SOURCE stamp
# naming where it came from, into <stage-dir>. Every `image:` in docker-compose.yml is pinned by
# STACK_VERSION, which the appliance derives from its baked VERSION — so an image built from a
# tree that is AHEAD of that release bakes a compose file assuming image content the pinned tags
# predate (#1098 was one instance: a healthcheck script the published image did not carry, and
# the symptom was a permanently-unhealthy container). The fix is structural: when the tag exists,
# the compose file comes from it, so compose and images agree by construction; when it does not,
# this IS the release being prepared and the tree is the right source (release.sh tags this very
# commit). The one silent case left — a clone that simply has not fetched the tag — is refused,
# because it would bake the tree's compose under a version that already shipped a different one.
# The stamp records the resolved commit, not just the tag name: a tag can be re-pointed, and
# verify-image compares the shipped file against exactly what was staged.
stage_compose() { # <version-tag> <stage-dir>  -> prints the COMPOSE_SOURCE line
    local tag="$1" dir="$2" sha remote_rc
    mkdir -p "$dir" || return 1
    rm -f "$dir/docker-compose.yml" "$dir/COMPOSE_SOURCE" || return 1
    if [ -n "${PITHEAD_OS_COMPOSE_FILE:-}" ]; then
        [ -r "$PITHEAD_OS_COMPOSE_FILE" ] && [ -f "$PITHEAD_OS_COMPOSE_FILE" ] && [ ! -L "$PITHEAD_OS_COMPOSE_FILE" ] || {
            echo "PITHEAD_OS_COMPOSE_FILE: $PITHEAD_OS_COMPOSE_FILE is not a readable file" >&2
            return 1
        }
        cp "$PITHEAD_OS_COMPOSE_FILE" "$dir/docker-compose.yml" || return 1
        sha="$(sha256sum "$dir/docker-compose.yml" | cut -d' ' -f1)" || return 1
        printf 'file sha256:%s\n' "$sha" >"$dir/COMPOSE_SOURCE" || return 1
    elif sha=$(git rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null); then
        git show "$sha:docker-compose.yml" >"$dir/docker-compose.yml" || return 1
        printf 'tag %s %s\n' "$tag" "$sha" >"$dir/COMPOSE_SOURCE" || return 1
    else
        if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then remote_rc=0; else remote_rc=$?; fi
        if [ "$remote_rc" -eq 0 ]; then
            echo "==> tag $tag exists on origin but not in this clone; refusing to bake the tree's compose file under a released version. Run: git fetch --tags" >&2
            return 1
        fi
        [ "$remote_rc" -eq 2 ] || {
            echo "==> could not determine whether tag $tag exists on origin; refusing to bake the tree's compose file." >&2
            return 1
        }
        cp docker-compose.yml "$dir/docker-compose.yml" || return 1
        printf 'tree\n' >"$dir/COMPOSE_SOURCE" || return 1
    fi
    cat "$dir/COMPOSE_SOURCE" || return 1
}

# A bench build that leaves the DEFAULT registry in place will ask it for
# pithead-<service>:$STACK_VERSION at first boot. Only the wizard's image is baked (below), so
# every other service is a pull — and an UNRELEASED version has no such tags anywhere public.
# The appliance then provisions, publishes its dashboard credentials, and comes up with ZERO
# containers; five battery legs report that and take up to 25 minutes each to do it (#2043).
#
# The refs are the same ones verify_release_images checks, and the same five the bench publishes
# to a local registry before a battery. Refuse here, in seconds, naming the remedy — the failure
# is in the BUILD's configuration, not in the appliance, and the battery cannot tell the
# difference from the inside.
#
# An unreachable registry refuses too, and correctly: an appliance built against a registry this
# host cannot read is an appliance that cannot pull either.
require_pullable_services() { # <registry> <stack-version>
    local registry="$1" version="$2" svc missing=""
    for svc in tor monero p2pool xmrig-proxy dashboard; do
        docker manifest inspect "${registry}/pithead-${svc}:${version}" >/dev/null 2>&1 ||
            missing="${missing} pithead-${svc}:${version}"
    done
    [ -z "$missing" ] && return 0
    {
        echo "build-image: refusing a bench build whose services could not be resolved."
        echo "  ${registry} cannot serve:${missing}"
        echo "  VERSION is ${version#v} and only the wizard image is baked, so every other service"
        echo "  is a pull at first boot. This image would provision and then run ZERO containers,"
        echo "  and the battery would spend up to 25 minutes per leg discovering it (#2043)."
        echo "  Publish the five first-party images to a registry this host and the guest can both"
        echo "  reach, then rebuild with PITHEAD_REGISTRY=<host:port> (and PITHEAD_REGISTRY_CA=<ca.crt>"
        echo "  when that registry is TLS). See tests/os/README.md."
    } >&2
    return 1
}

# Test seam: `PITHEAD_BUILD_IMAGE_TEST=1 source os/build-image.sh [args...]` parses args and
# defines apt_fetch_failure_hint and stage_compose above, then returns here instead of touching
# docker — lets tests/stack exercise flag parsing, the remedy hint and the staging without a build.
if [ "${PITHEAD_BUILD_IMAGE_TEST:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# The root CLI is generated and git-ignored. Build it before either the stage-only CI path or the
# full Docker build consumes the repository root as its context.
bash scripts/build-pithead.sh

# Bake the wizard's container image into the appliance: first boot must reach the setup page
# without a registry (the operator may have no working network config yet, and the plan's
# offline-first-boot property depends on it). The rest of the release's images are pulled at
# provision time for now — baking the full set is tracked with the appliance-size work.
STACK_VERSION="v$(tr -d ' \t\r\n' <VERSION)"
# os/build/ is git-ignored, so staging there keeps the tree clean (the build stamps itself dirty
# otherwise, and mkimage refuses a dirty stamp). The Dockerfile COPYs both files from this path.
COMPOSE_SOURCE="$(stage_compose "$STACK_VERSION" os/build/stage)" || exit 1
echo "==> compose file staged from: $COMPOSE_SOURCE"
if [ "${STAGE_ONLY:-0}" = 1 ]; then
    echo "==> --stage-only: os/build/stage/ is ready; stopping before the build"
    exit 0
fi
WIZARD_IMAGE="${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-dashboard:${STACK_VERSION}"
WIZARD_SOURCE="$WIZARD_IMAGE"
# A DEBUG build against a non-default registry pins that registry into every unit that can run
# pithead and tells podman how to trust it — a CA file (PITHEAD_REGISTRY_CA) for a TLS registry, else an
# insecure (HTTP) entry (#1892). The wizard archive above is NAMED with the build-time
# registry and first boot re-derives the same name at runtime, so the two must agree, and nothing
# on the box sets the runtime half otherwise. Release builds never carry either file.
TEST_REGISTRY=""
if [ -n "${PITHEAD_TEST_SSH_PUBKEY:-}" ] && [ -n "${PITHEAD_REGISTRY:-}" ] &&
    [ "$PITHEAD_REGISTRY" != "ghcr.io/p2pool-starter-stack" ]; then
    TEST_REGISTRY="$PITHEAD_REGISTRY"
    if [ -n "${PITHEAD_REGISTRY_CA:-}" ]; then
        [ -s "$PITHEAD_REGISTRY_CA" ] || {
            echo "PITHEAD_REGISTRY_CA: $PITHEAD_REGISTRY_CA is not a readable file" >&2
            exit 1
        }
        echo "==> debug build: the image will provision from $TEST_REGISTRY (TLS, CA $PITHEAD_REGISTRY_CA)"
    else
        echo "==> debug build: the image will provision from $TEST_REGISTRY (insecure for podman)"
    fi
fi
if [ -n "${PITHEAD_TEST_SSH_PUBKEY:-}" ] && [ -z "$TEST_REGISTRY" ]; then
    require_pullable_services "${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}" "$STACK_VERSION" || exit 1
fi
mkdir -p os/rootfs/images
echo "==> staging wizard image $WIZARD_IMAGE"
if [ -n "${PITHEAD_WIZARD_IMAGE:-}" ]; then
    is_immutable_image_ref "$PITHEAD_WIZARD_IMAGE" || {
        echo "PITHEAD_WIZARD_IMAGE must be a lowercase repo@sha256:<64 hex> reference" >&2
        exit 1
    }
    WIZARD_SOURCE="$PITHEAD_WIZARD_IMAGE"
    docker pull -q "$WIZARD_SOURCE" >/dev/null
    docker tag "$WIZARD_SOURCE" "$WIZARD_IMAGE"
elif [ "${PITHEAD_WIZARD_FROM_REGISTRY:-0}" = "1" ]; then
    # Release path: the published image carries the wizard module.
    docker pull -q "$WIZARD_IMAGE" >/dev/null
else
    # No mtime cache, EVER. The old test compared the archive against dashboard — the
    # DIRECTORY, whose mtime only moves when a direct child is added or removed. Editing a file
    # deep inside it changes nothing, so the cache said "fresh" forever and stale wizards
    # reached three separate benches. Docker's own layer cache makes the rebuild cheap; a
    # correctness decision must not hang on directory-mtime semantics.
    # Development path, and the default until a release ships the wizard: mining_dashboard.wizard
    # only exists in this working tree, so a pulled image would start and immediately exit with
    # "No module named mining_dashboard.wizard". Build the image the appliance will actually run.
    docker build -q -t "$WIZARD_IMAGE" dashboard >/dev/null
fi
# Harness builds only: stamp the marker INTO the dashboard image, at a path the wizard serves
# (/static/os-test-marker.txt). The tag is identical across builds, so this is the only way a
# battery can tell which dashboard actually answers after an update or reinstall — the #798
# regression was precisely "new OS, old dashboard, every check green". Release builds set no
# marker and get no extra layer.
if [ -n "${PITHEAD_TEST_MARKER:-}" ]; then
    # USER root/pithead mirrors dashboard/Dockerfile: the runtime user cannot write /app.
    printf 'FROM %s\nUSER root\nRUN printf %%s "%s" >/app/mining_dashboard/web/static/os-test-marker.txt\nUSER pithead\n' \
        "$WIZARD_SOURCE" "$PITHEAD_TEST_MARKER" | docker build -q -t "$WIZARD_IMAGE" - >/dev/null
fi
docker save "$WIZARD_IMAGE" | gzip -1 >os/rootfs/images/dashboard.tar.gz

# Stamp the commit into the image. A release build once shipped a dashboard two commits stale
# because it pulled from an intermediate clone, and nothing in the artifact could reveal it —
# the image looked correct and behaved like the previous build. verify-image asserts this.
BUILD_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BUILD_DIRTY=""
git diff --quiet 2>/dev/null || BUILD_DIRTY="-dirty"
printf '%s%s\n' "$BUILD_COMMIT" "$BUILD_DIRTY" >os/rootfs/BUILD_COMMIT
echo "==> building from commit ${BUILD_COMMIT}${BUILD_DIRTY}"

# Overridable so a parallel release build cannot collide with a harness build on the same host.
# It is an env var and NOT an edit to this file: the build stamps its own commit, and a sed
# against the working tree would mark every release image "-dirty" and fail its own gate.
ROOTFS_TAG="${PITHEAD_ROOTFS_TAG:-pithead-os-rootfs}"

echo "==> rootfs: container build + export"
# --fresh-index (#929) stamps a new value into the Dockerfile's APT_INDEX_STAMP ARG, which busts
# only the apt-update layer it precedes — every other layer still caches normally.
apt_index_stamp=0
[ "${FRESH_INDEX:-0}" = "1" ] && apt_index_stamp="$(date +%s)"
build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT
if ! docker build -f os/rootfs/Dockerfile -t "$ROOTFS_TAG" \
    --build-arg PITHEAD_TEST_SSH_PUBKEY="${PITHEAD_TEST_SSH_PUBKEY:-}" \
    --build-arg PITHEAD_TEST_MARKER="${PITHEAD_TEST_MARKER:-}" \
    --build-arg PITHEAD_UPDATER="${PITHEAD_UPDATER:-rauc}" \
    "${rigforge_build_args[@]}" \
    --build-arg APT_INDEX_STAMP="$apt_index_stamp" . 2>&1 | tee "$build_log"; then
    apt_fetch_failure_hint "$(cat "$build_log")"
    exit 1
fi
cid=$(docker create "$ROOTFS_TAG")
mkdir -p os/build
docker export --output os/build/pithead-root.tar "$cid"
docker rm "$cid" >/dev/null
if [ -n "$TEST_REGISTRY" ]; then
    # Appended to the exported rootfs rather than baked by the Dockerfile: the release rootfs is
    # then byte-identical to a build that never heard of a test registry. Leaf files only — a
    # directory entry would re-apply the staging dir's mode onto /etc on extraction.
    stage="$(mktemp -d)"
    # pithead-control.service is created under /run after boot. Its baked /etc drop-in still applies
    # when that runtime unit appears, so dashboard apply/backup/update actions keep this registry too.
    for u in pithead-boot pithead-firstboot pithead-setup-again pithead-control; do
        mkdir -p "$stage/etc/systemd/system/$u.service.d"
        printf '[Service]\nEnvironment=PITHEAD_REGISTRY=%s\n' "$TEST_REGISTRY" \
            >"$stage/etc/systemd/system/$u.service.d/pithead-test-registry.conf"
    done
    # An SSH shell running ./pithead by hand reads /etc/environment through PAM, never a unit's
    # drop-in (#1931): the pin goes there too, appended to the file the rootfs already carries
    # (PITHEAD_ENGINE, Dockerfile) so the later tar entry replaces it whole and loses nothing.
    tar -xOf os/build/pithead-root.tar etc/environment >"$stage/etc/environment" || {
        echo "build-image: the exported rootfs has no etc/environment to pin the registry into" >&2
        exit 1
    }
    printf 'PITHEAD_REGISTRY=%s\n' "$TEST_REGISTRY" >>"$stage/etc/environment"
    # containers/image reads /etc/containers/certs.d/<host:port>/ca.crt for a TLS registry; the
    # insecure entry is the HTTP fallback. One or the other, never both.
    if [ -n "${PITHEAD_REGISTRY_CA:-}" ]; then
        mkdir -p "$stage/etc/containers/certs.d/${TEST_REGISTRY%%/*}"
        cp "$PITHEAD_REGISTRY_CA" "$stage/etc/containers/certs.d/${TEST_REGISTRY%%/*}/ca.crt"
    else
        mkdir -p "$stage/etc/containers/registries.conf.d"
        printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "${TEST_REGISTRY%%/*}" \
            >"$stage/etc/containers/registries.conf.d/pithead-test-registry.conf"
    fi
    (cd "$stage" && find etc -type f) |
        tar --append -f os/build/pithead-root.tar --owner=0 --group=0 --mode=0644 -C "$stage" -T -
    rm -r "$stage"
fi
echo "==> rootfs: os/build/pithead-root.tar ($(du -h os/build/pithead-root.tar | cut -f1))"
