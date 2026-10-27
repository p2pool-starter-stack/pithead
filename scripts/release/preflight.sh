#!/usr/bin/env bash

LINT_TOOLCHAIN=(shellcheck shfmt node npx uv uvx go)
GO_MIN_MINOR=21
BENCH_TIER4_CONTEXT="bench-ci/tier4"

bench_tier4_reject() {
    [ "$DRY_RUN" -eq 1 ] || die "$@"
    warn "$* [--dry-run: continuing]"
}

require_bench_tier4() {
    local app_id statuses state slug="${BENCH_CI_APP_SLUG:-}" expected="${BENCH_CI_APP_ID:-}"
    if ! command -v gh >/dev/null 2>&1; then
        bench_tier4_reject "gh is required to read the $BENCH_TIER4_CONTEXT status for release commit $GIT_COMMIT."
        return 0
    fi
    if ! [[ "$expected" =~ ^[1-9][0-9]*$ ]]; then
        bench_tier4_reject "BENCH_CI_APP_ID must be the numeric id of the installed bench-ci GitHub App."
        expected="" # dry run only: the id cannot be checked, but the status lookup still previews
    fi
    if ! [[ "$slug" =~ ^[a-z0-9-]+$ ]]; then
        bench_tier4_reject "BENCH_CI_APP_SLUG must be the slug of the installed bench-ci GitHub App (pithead-bench-ci)."
        return 0 # without a slug there is nothing left to look up
    fi
    if ! app_id="$(gh api "apps/$slug" | jq -r '.id // empty')"; then
        bench_tier4_reject "Could not resolve GitHub App $slug."
        return 0
    fi
    if [ -n "$expected" ] && [ "$app_id" != "$expected" ]; then
        bench_tier4_reject "GitHub App $slug has id ${app_id:-missing}, expected $expected."
        return 0
    fi
    # ponytail: reads only the first 100 statuses on the commit. A commit carrying more than that,
    # with the bench-ci entry aged out of the page, reads as missing and REFUSES the release —
    # it fails closed, never open. Paginate if a release SHA ever collects that many statuses.
    if ! statuses="$(gh api "repos/p2pool-starter-stack/pithead/commits/$GIT_COMMIT/statuses?per_page=100")"; then
        bench_tier4_reject "Could not read the $BENCH_TIER4_CONTEXT status for release commit $GIT_COMMIT."
        return 0
    fi
    if ! state="$(jq -r --arg context "$BENCH_TIER4_CONTEXT" --arg creator "${slug}[bot]" \
        'map(select(.context == $context and .creator.login == $creator)) | first | .state // empty' <<<"$statuses")"; then
        bench_tier4_reject "Could not parse the $BENCH_TIER4_CONTEXT status for release commit $GIT_COMMIT."
        return 0
    fi
    if [ "$state" != success ]; then
        bench_tier4_reject "Release commit $GIT_COMMIT has no successful $BENCH_TIER4_CONTEXT status from GitHub App ${expected:-unset} (got: ${state:-missing})."
        return 0
    fi
    ok "Bench tier-4 gate passed for $GIT_COMMIT."
}

load_release_env() {
    local file="${PITHEAD_RELEASE_ENV:-$RELEASE_KEY_DIR/env}" label line name value mode
    local number=0 loaded=0 retained=0
    label="${file##*/}"
    [ ! -L "$file" ] || die "Release env $label is a symlink."
    if [ ! -e "$file" ]; then
        [ -z "${PITHEAD_RELEASE_ENV+x}" ] || die "Release env $label does not exist."
        return 0
    fi
    [ -f "$file" ] && [ -O "$file" ] || die "Release env $label must be a regular file owned by the invoking user."
    mode="$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")" || die "Could not read permissions of release env $label."
    [[ "$mode" =~ ^[0-7]+$ ]] || die "Invalid permissions of release env $label."
    [ "$((8#$mode & 022))" -eq 0 ] || die "Release env $label is group- or world-writable."
    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        line="${line#export }"
        name="${line%%=*}"
        [[ "$line" == *=* && "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            die "Release env $label line $number: malformed assignment."
        case "$name" in
        BENCH_CI_APP_ID | BENCH_CI_APP_SLUG | RELEASE_INTEGRATION_ARGS | RELEASE_TOOL_PATH) ;;
        *) die "Release env $label line $number: name is not allowed." ;;
        esac
        value="${line#*=}"
        case "$value" in
        \"* | \'*)
            [ "${#value}" -ge 2 ] && [ "${value:0:1}" = "${value: -1}" ] ||
                die "Release env $label line $number: unmatched quote."
            value="${value:1:${#value}-2}"
            ;;
        *\" | *\') die "Release env $label line $number: unmatched quote." ;;
        esac
        if [ "${!name+x}" = x ]; then
            log "Release env $label: $name already set in environment."
            retained=$((retained + 1))
        else
            export "$name=$value"
            log "Release env $label: loaded $name."
            loaded=$((loaded + 1))
        fi
    done <"$file"
    log "Release env $label: $loaded loaded, $retained retained."
}

apply_release_path() {
    local rest="${RELEASE_TOOL_PATH:-}" element mode
    [ -n "$rest" ] || return 0
    while :; do
        element="${rest%%:*}"
        case "$element" in
        /*) ;;
        *) die "RELEASE_TOOL_PATH element '$element' must be an absolute directory (empty elements are refused)." ;;
        esac
        [ -d "$element" ] || die "RELEASE_TOOL_PATH element '$element' is not an existing directory."
        mode="$(stat -L -c %a "$element" 2>/dev/null || stat -L -f %Lp "$element")" ||
            die "Could not read permissions of RELEASE_TOOL_PATH element '$element'."
        [[ "$mode" =~ ^[0-7]+$ ]] || die "Invalid permissions of RELEASE_TOOL_PATH element '$element'."
        [ "$((8#$mode & 022))" -eq 0 ] || die "RELEASE_TOOL_PATH element '$element' is group- or world-writable."
        [[ "$rest" == *:* ]] || break
        rest="${rest#*:}"
    done
    PATH="$RELEASE_TOOL_PATH:$PATH"
    export PATH
}

check_release_toolchain() {
    local tool resolved go_version missing=()
    for tool in "${LINT_TOOLCHAIN[@]}"; do
        if resolved="$(command -v "$tool")"; then
            log "Lint/test tool $tool: $resolved"
        else
            missing+=("$tool")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "Missing lint/test tool(s): ${missing[*]}. Effective PATH: $PATH. Set RELEASE_TOOL_PATH to the installed tool directories; see docs/dev/release-server.md § The lint/release toolchain."
    fi
    go_version="$(go version 2>&1)" || true
    [[ "$go_version" =~ go1\.([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -ge "$GO_MIN_MINOR" ] ||
        die "go 1.$GO_MIN_MINOR or newer is required by test-stack's go-raise-watch self-test (found: ${go_version:-no output}). Set RELEASE_TOOL_PATH to a newer Go; see docs/dev/release-server.md § The lint/release toolchain."
    ok "Lint/test toolchain present (${LINT_TOOLCHAIN[*]})."
}

require_release_toolchain() {
    [ "$SKIP_TESTS" -eq 1 ] || check_release_toolchain
}

require_clean_release_tree() {
    local tree_status
    [ "$ALLOW_DIRTY" -eq 0 ] || [ "$DRY_RUN" -eq 1 ] || die "--allow-dirty requires --dry-run."
    tree_status="$(git status --porcelain)" || die "Could not inspect the working tree at $GIT_COMMIT."
    [ -z "$tree_status" ] ||
        { [ "$DRY_RUN" -eq 1 ] && [ "$ALLOW_DIRTY" -eq 1 ]; } ||
        die "Working tree differs from $GIT_COMMIT. Commit/stash first (or use --allow-dirty with --dry-run)."
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

check_registry_policy() {
    check_registry_write_tuning
    if [ -n "${PITHEAD_BUILDKITD_CONFIG:-}" ] &&
        { [ ! -f "$PITHEAD_BUILDKITD_CONFIG" ] || [ ! -r "$PITHEAD_BUILDKITD_CONFIG" ]; }; then
        die "PITHEAD_BUILDKITD_CONFIG must name a readable file."
    fi
    if [ "${PITHEAD_REHEARSAL:-0}" = 1 ] && [ "$REGISTRY" = "$PROD_REGISTRY" ]; then
        die "PITHEAD_REHEARSAL=1 requires a non-production registry namespace."
    fi
    if [ "$REGISTRY" != "$PROD_REGISTRY" ] && [ "$DRY_RUN" -eq 0 ] && [ "${PITHEAD_REHEARSAL:-0}" != 1 ]; then
        warn "A real cut will publish a bundle naming $REGISTRY; PITHEAD_REHEARSAL=1 rehearses without tagging."
    fi
}

preflight() {
    check_registry_policy
    stage "1/7  Preflight"
    load_release_env
    apply_release_path
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repository."
    # release.sh enables errexit before calling this stage.
    # shellcheck disable=SC2164
    cd "$REPO_ROOT"
    GIT_COMMIT="$(git rev-parse HEAD)"
    GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    require_clean_release_tree
    log "Building the generated pithead CLI"
    bash scripts/build-pithead.sh || die "Could not build the pithead CLI."
    [ -f VERSION ] && [ -f docker-compose.yml ] || die "VERSION / docker-compose.yml not found at the repo root."
    command -v docker >/dev/null 2>&1 || die "docker is required."
    docker buildx version >/dev/null 2>&1 || die "docker buildx is required (for digest-level promotion)."
    # Only the test gate needs the lint toolchain — skip the check when it does not run.
    require_release_toolchain
    apply_signing_defaults
    resolve_signing
    check_verifier_image

    bash "$REPO_ROOT/scripts/release/resolve-pins.sh" ||
        die "A third-party image pin does not match what its registry serves for that tag — see above. The digest is what actually runs, so cutting now would announce a version the stack is not running."

    STACK_VERSION="$(tr -d ' \t\r\n' <VERSION)"
    is_semver "$STACK_VERSION" || die "VERSION ('$STACK_VERSION') is not SemVer (expected X.Y.Z)."
    TAG="v$STACK_VERSION"
    STAGING_TAG="${TAG}-rc.${RC}"
    # Used by the image labels and bundle manifest in the later release stages.
    # shellcheck disable=SC2034
    BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
