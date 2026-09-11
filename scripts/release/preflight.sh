#!/usr/bin/env bash
# Sourced by release.sh; shares its configuration and stage state.

# The CLI tools the blocking test gate (`make test` → `make lint`) shells out to: shellcheck + shfmt
# (lint-sh), node/npx (lint-js/md/toml), uv/uvx (lint-py/lint-yaml). A reimaged release box loses these
# (#426 — the v1.3.0 cut died ~1 min in with a bare `shellcheck: not found`). docker/jq are checked
# elsewhere. Verify them here so a missing tool fails preflight with an actionable message, before any
# build, instead of mid-gate.
LINT_TOOLCHAIN=(shellcheck shfmt node npx uv uvx)

check_release_toolchain() {
    local tool missing=()
    for tool in "${LINT_TOOLCHAIN[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "Missing lint/test tool(s): ${missing[*]} — the release box needs the lint toolchain before the test gate can run. Provision it (apt + the pinned uv installer): see docs/dev/release-server.md § Provisioning the server. (Or --skip-tests to bypass the gate — NOT recommended.)"
    fi
    ok "Lint/test toolchain present (${LINT_TOOLCHAIN[*]})."
}
# --- Release signing (#376, #960) -----------------------------------------------------------------
#
# Signing is MANDATORY to publish, because it is mandatory to consume. Once `cosign.pub` is committed
# it ships inside every bundle, and from that release on `pithead`'s one-click upgrade refuses any
# release with no `pithead.tar.gz.sig`. So a cut made on a box with no key does not produce a
# degraded release — it produces a bundle every install in the fleet rejects, and GitHub release
# assets are immutable, so the signature can never be attached afterwards. That is how v1.18.0 had to
# be withdrawn and re-cut (#960). The decision below therefore aborts the cut rather than warning.
#
# It also runs on --dry-run, and only the signing itself is skipped. The check used to sit inside
# `if [ "$DRY_RUN" -eq 0 ]`, which meant the one rehearsal that exists to catch a mis-configured
# signing box could only ever print "signing OFF" — the failure state, unconditionally (#1108).
# What the signing environment is missing, one gap per line; empty output means it is complete. Pure
# given PATH and the environment, so the tests can drive every combination without a release.
signing_env_gaps() {
    command -v cosign >/dev/null 2>&1 || echo "cosign is not on PATH"
    if [ -z "${COSIGN_KEY:-}" ]; then
        echo "COSIGN_KEY is unset"
    elif [ ! -f "$COSIGN_KEY" ]; then
        echo "COSIGN_KEY names no file ($COSIGN_KEY)"
    fi
    # Set-but-empty is a legitimate key with no passphrase; unset is not. cosign would prompt for it
    # at stage 6b — after the images are promoted, where there is nothing left to abort into.
    [ -n "${COSIGN_PASSWORD+x}" ] || echo "COSIGN_PASSWORD is unset"
}

# The release box keeps the key and its passphrase at fixed paths under $HOME (#77 phase 1), so a cut
# there needs no exports at all. Applied BEFORE the gap check, so what gets validated is what the cut
# will actually use, and only when the variable is unset — an explicit COSIGN_KEY still wins, and an
# explicitly wrong one still aborts. Deliberately NOT part of signing_env_gaps: that function is
# driven from the tests across every combination of the environment, and one that read $HOME would
# answer differently on the release box than in CI.
RELEASE_KEY_DIR="${RELEASE_KEY_DIR:-$HOME/.config/pithead-release}"

apply_signing_defaults() {
    COSIGN_KEY="${COSIGN_KEY:-$RELEASE_KEY_DIR/cosign.key}"
    # Same custody as the key: a file readable only by the release user, so the passphrase never has
    # to be typed or pasted into a command line. Only when COSIGN_PASSWORD is unset — set-but-empty
    # is a legitimate key with no passphrase (see signing_env_gaps) and must not be overwritten.
    if [ -z "${COSIGN_PASSWORD+x}" ] && [ -f "$RELEASE_KEY_DIR/cosign.passphrase" ]; then
        COSIGN_PASSWORD="$(cat "$RELEASE_KEY_DIR/cosign.passphrase")"
        export COSIGN_PASSWORD
    fi
}

# Both signing calls pass `--tlog-upload=false`, which cosign v3 removed. A box that has drifted to
# v3 passes every other check here and then dies at stage 6b with the tag pushed and the images
# promoted (#960 — the bench box had drifted exactly this way). Probe the flag rather than parse a
# version: the flag is the thing that actually has to work, and it stays true across future majors.
cosign_flags_supported() { cosign sign-blob --help 2>&1 | grep -q -- '--tlog-upload'; }

resolve_signing() {
    local gaps
    gaps="$(signing_env_gaps)"
    if [ -z "$gaps" ]; then
        cosign_flags_supported ||
            die "This box's cosign does not support --tlog-upload, which both signing calls pass — cosign v3 removed it. The cut would die at stage 6b with the images already promoted. Install the pinned cosign: docs/dev/release-server.md § The release signing key."
        COSIGN_ENABLED=1
        ok "Release signing ON — the promoted digests and the install bundle will be signed."
        return 0
    fi
    COSIGN_ENABLED=0
    # No committed public key means no install has a verifier, so nothing in the field fails closed
    # on a missing signature. Honest, and the state every release before v1.18.1 shipped in.
    if [ ! -f cosign.pub ]; then
        warn "Release signing OFF — no cosign.pub is committed, so installs have no key to verify against and will proceed unverified (${gaps//$'\n'/; })."
        return 0
    fi
    if [ "$UNSIGNED" -eq 1 ]; then
        warn "Release signing OFF by --unsigned, with cosign.pub committed: this release will carry no pithead.tar.gz.sig, and every one-click upgrade in the field REFUSES a release that has none. Release assets are immutable — the signature cannot be added later."
        return 0
    fi
    die "Release signing is not configured on this box: ${gaps//$'\n'/; }. cosign.pub is committed, so the bundle this cut would publish is one every one-click upgrade refuses, and release assets are immutable — it could not be signed afterwards (#960). Configure the key (docs/dev/release-server.md § The release signing key), or pass --unsigned to publish an unsigned release deliberately."
}

# --- The release verifier image (#1084) -----------------------------------------------------------
#
# Since #1072 every install verifies its images and its one-click upgrade bundle by running ONE
# digest-pinned cosign container — `pithead`'s COSIGN_IMAGE — so that image is the trust root for the
# whole fleet, and it was the one input nothing checked. The stack tests exercise the logic around it
# against a fake `docker`, which passes identically whether the digest is real, typo'd or deleted
# upstream; the tier-4 e2e deploys a source checkout, where verification is skipped by design; and
# release-smoke runs AFTER the publish, when the assets are already immutable. So a bad pin shipped a
# stack that cannot start, and the operator-facing failure reads "signature verification FAILED" —
# tampering, not our pin having moved. The realistic cause is mundane: a CVE bump, one wrong
# character, every test still green.

# The pin, read from `pithead` the same way pin() reads the component versions out of the Dockerfiles.
# -a because `pithead` is a file this repo GENERATES and knows to be text, and grep's binary
# heuristic is filesystem-dependent: over Docker Desktop's macOS file sharing it calls this exact
# file binary and prints nothing, so the pin comes back EMPTY rather than wrong (#2078). An empty
# pin in a signing preflight is the worst shape of failure this function has.
cosign_image_pin() { grep -a -oE '^readonly COSIGN_IMAGE="[^"]+"' pithead | head -1 | cut -d'"' -f2; }

# One verify-blob through the pinned container, mirroring pithead's cosign_run: a single read-only
# mount at /w with every path relative to it, and HOME=/tmp so cosign does not warn about a TUF cache
# it cannot write. Same shape the install side runs, so a mount or path mistake shows up here first.
verifier_verify_blob() { # <probe-dir> <image>
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$1:/w:ro" -w /w "$2" \
        verify-blob --key cosign.pub --signature blob.sig --insecure-ignore-tlog=true blob >/dev/null 2>&1
}

# Prove the pinned verifier before anything is built: it pulls, it runs, and — when this box can sign
# — it accepts a signature made with THIS release key and refuses a tampered blob. The round trip is
# what makes the check real rather than a liveness probe: it also catches a `cosign.pub` that no
# longer matches `COSIGN_KEY`, which would make every install refuse every artifact of this release.
check_verifier_image() {
    local img
    img="$(cosign_image_pin)"
    [ -n "$img" ] || die "Could not read COSIGN_IMAGE out of ./pithead — the release verifier pin moved or changed shape, so this cut cannot validate the thing every install verifies with."
    case "$img" in
    *@sha256:*) ;;
    *) die "COSIGN_IMAGE is not pinned by digest ($img). On a tag, a hostile registry could serve a 'cosign' that exits 0 on everything and turn verification into theatre — pin it by @sha256 (pithead: COSIGN_IMAGE)." ;;
    esac
    docker run --rm "$img" version >/dev/null 2>&1 ||
        die "The pinned release verifier will not run: $img. Every install and every one-click upgrade pulls exactly this digest, so a release cut against it would fail at the first 'up'. Check the pin in pithead (COSIGN_IMAGE) and that the digest is still published."
    if [ "${COSIGN_ENABLED:-0}" -ne 1 ]; then
        warn "Release verifier pulls and runs, but the signature round trip was skipped — this cut is not signing, so there is no signature to prove it against."
        return 0
    fi
    local d
    d="$(mktemp -d)"
    printf 'pithead release verifier probe\n' >"$d/blob"
    cp cosign.pub "$d/cosign.pub"
    cosign sign-blob --key "${COSIGN_KEY:-}" --tlog-upload=false --yes --output-signature "$d/blob.sig" "$d/blob" >/dev/null 2>&1 ||
        die "Could not sign a probe blob with COSIGN_KEY — the key or COSIGN_PASSWORD is wrong. Better here than at stage 6b, with the images already promoted."
    verifier_verify_blob "$d" "$img" ||
        die "The pinned release verifier refused a signature this box just made with COSIGN_KEY. Either the verifier image is not the cosign it claims to be, or the committed cosign.pub is not the public half of COSIGN_KEY — in which case every install would refuse every artifact of this release."
    printf 'tampered\n' >>"$d/blob"
    if verifier_verify_blob "$d" "$img"; then
        die "The pinned release verifier ACCEPTED a tampered blob — it is not verifying anything. Every install trusts this image (pithead: COSIGN_IMAGE); do not cut a release against it."
    fi
    rm -rf "$d"
    ok "Release verifier validated end to end (${img##*@}: signs, verifies, refuses a tampered blob)."
}

preflight() {
    stage "1/7  Preflight"
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repository."
    # release.sh enables errexit before calling this stage.
    # shellcheck disable=SC2164
    cd "$REPO_ROOT"
    log "Building the generated pithead CLI"
    bash scripts/build-pithead.sh || die "Could not build the pithead CLI."
    [ -f VERSION ] && [ -f docker-compose.yml ] || die "VERSION / docker-compose.yml not found at the repo root."
    command -v docker >/dev/null 2>&1 || die "docker is required."
    docker buildx version >/dev/null 2>&1 || die "docker buildx is required (for digest-level promotion)."
    # Only the test gate needs the lint toolchain — skip the check on the paths that don't run it.
    if [ "$DRY_RUN" -eq 0 ] && [ "$SKIP_TESTS" -eq 0 ] && [ "$RESUME_PROMOTE" -eq 0 ]; then
        check_release_toolchain
    fi
    apply_signing_defaults
    resolve_signing
    check_verifier_image

    bash "$REPO_ROOT/scripts/release/resolve-pins.sh" ||
        die "A third-party image pin does not match what its registry serves for that tag — see above. The digest is what actually runs, so cutting now would announce a version the stack is not running."

    STACK_VERSION="$(tr -d ' \t\r\n' <VERSION)"
    is_semver "$STACK_VERSION" || die "VERSION ('$STACK_VERSION') is not SemVer (expected X.Y.Z)."
    TAG="v$STACK_VERSION"
    STAGING_TAG="${TAG}-rc.${RC}"
    GIT_COMMIT="$(git rev-parse HEAD)"
    GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    # Used by the image labels and bundle manifest in the later release stages.
    # shellcheck disable=SC2034
    BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$ALLOW_DIRTY" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
        die "Working tree is dirty. Commit/stash first, or pass --allow-dirty."
    fi
    [ "$GIT_BRANCH" = "develop" ] || warn "Releasing from '$GIT_BRANCH', not develop."

    if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
        die "Git tag $TAG already exists — bump VERSION before cutting a new release."
    fi
    # Best-effort: warn if the promoted tag already exists in the registry (needs auth; non-fatal).
    if docker buildx imagetools inspect "$(image_for dashboard):$TAG" >/dev/null 2>&1; then
        warn "$(image_for dashboard):$TAG already exists in the registry — promotion would overwrite it."
    fi

    log "Version:   $STACK_VERSION  (tag $TAG, staging $STAGING_TAG)"
    log "Commit:    $GIT_COMMIT ($GIT_BRANCH)"
    log "Registry:  $REGISTRY  prefix '$IMAGE_PREFIX'"
    log "Pins:      p2pool $(pin p2pool) · monerod $(pin monero) · xmrig-proxy $(pin xmrig-proxy)"
    ok "Preflight passed."
}
