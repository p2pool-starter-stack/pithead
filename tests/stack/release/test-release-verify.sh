# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Release-VERIFY domain (#1105 Phase 1): the install side of signing — verify_release_images'
# fail-closed image-verification gate, and cosign_container_path's host-to-container path mapping.
# Split from test-release-signing.sh, which keeps the producer side (what a cut signs and what it
# refuses to publish): the two are exercised by different fixtures and neither needs the other's.
# Sourced by tests/stack/run.sh after lib.sh. (The #291 firewall-ordering assertions trailing
# cosign_container_path are not here — tor/network, not signing, the documented map trap; they live
# in test-tor-network.sh.)
echo "== black-box: verify_release_images fail-closed gate (#376) =="
# The verification decision itself, against a fake docker on a PINNED PATH ($VRI/bin:/usr/bin:/bin
# — coreutils stay, so the host can never decide the outcome). Since #1072 the verifier is a
# container, so the stub is `docker`, not `cosign`: it answers the availability probe, pretends the
# pinned image is already present, and logs the cosign argv that follows the image ref — which keeps
# every assertion below reading exactly as it did when cosign was a host binary. A release install
# is a dir without dashboard/Dockerfile.
VRI="$SANDBOX/verify376"
write_fake_docker "$VRI/bin"
write_unreachable_docker "$VRI/nodocker"

# A deterministic 64-hex digest per image, and a digest-pinned compose (#461) so verify has the same
# @sha256 bytes to check that a release install's compose would pull (#451). TOR_DG is what the tor
# assertions expect the tor image to be verified/failed against.
hex64() { printf "$1%.0s" $(seq 1 64); }
TOR_DG="sha256:$(hex64 1)"
write_pinned_compose() { # $1=dir  — one image: line per first-party suffix, each pinned by @sha256
    local d="$1" n=1 suffix
    : >"$d/docker-compose.yml"
    for suffix in tor monero p2pool xmrig-proxy dashboard; do
        printf '    image: ${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-%s:${STACK_VERSION:-dev}@sha256:%s\n' \
            "$suffix" "$(hex64 "$n")" >>"$d/docker-compose.yml"
        n=$((n + 1))
    done
}
write_pinned_compose "$VRI"

# No cosign.pub (an install older than the first signed release): documented fallback — proceed,
# but say loudly that nothing was verified.
out="$(PATH="$VRI/bin:/usr/bin:/bin" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "no pubkey -> pull proceeds (documented fallback)" "$?" "0"
assert_contains "no pubkey -> loud NOT-verified warning" "$out" "NOT be signature-verified"

# cosign.pub present but the verifier cannot run (docker daemon unreachable): FAIL CLOSED — an
# unavailable verifier must not silently disable verification.
printf 'fake release public key' >"$VRI/cosign.pub"
out="$(PATH="$VRI/nodocker:/usr/bin:/bin" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "pubkey without a runnable verifier -> pull aborts" "$?" "1"
assert_contains "verifier-missing abort names docker, not a host cosign" "$out" "docker is not available"

# Valid signatures (fake cosign exits 0): all 5 images verified with the committed key, no Rekor
# (--private-infrastructure), against the EXACT @sha256 digest compose pins and pulls (#451 — bound
# to the same bytes, not the mutable tag).
: >"$VRI/cosign.log"
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_LOG="$VRI/cosign.log" \
    PITHEAD_REGISTRY="ghcr.io/test" STACK_VERSION="v9.9.9" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "valid signatures -> pull proceeds" "$?" "0"
assert_eq "all 5 first-party images verified" "$(grep -c '^\[cosign\] verify ' "$VRI/cosign.log")" "5"
assert_contains "verify binds to the pinned digest, not the tag (#451)" \
    "$(cat "$VRI/cosign.log")" "verify --key cosign.pub --private-infrastructure ghcr.io/test/pithead-tor@$TOR_DG"
assert_not_contains "verify never resolves the mutable tag (#451)" "$(cat "$VRI/cosign.log")" "pithead-tor:v9.9.9"

# A signature that does not verify (fake cosign exits 1): FAIL CLOSED. This is the red test for the
# whole feature — bypass or soften the verification and it goes green-to-broken.
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_RC=1 \
    PITHEAD_REGISTRY="ghcr.io/test" STACK_VERSION="v9.9.9" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "bad signature -> pull aborts (fail closed)" "$?" "1"
assert_contains "bad-signature abort names the pinned image" "$out" "Signature verification FAILED for ghcr.io/test/pithead-tor@$TOR_DG"

# cosign.pub present but the compose is NOT digest-pinned (a pre-#461 or tampered bundle): FAIL
# CLOSED (#451). Without a digest there's nothing to bind verification to the pulled bytes, so the
# verify-then-pull window can't be closed — refuse rather than fall back to verifying the tag.
UNPINNED="$SANDBOX/verify451-unpinned"
mkdir -p "$UNPINNED"
printf 'fake release public key' >"$UNPINNED/cosign.pub"
printf '    image: ${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-tor:${STACK_VERSION:-dev}\n' >"$UNPINNED/docker-compose.yml"
: >"$VRI/cosign.log"
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_LOG="$VRI/cosign.log" run_sourced "$UNPINNED" verify_release_images 2>&1)"
assert_rc "un-pinned compose + key -> pull aborts (#451)" "$?" "1"
assert_contains "un-pinned abort explains the missing digest bind" "$out" "not digest-pinned"
assert_eq "un-pinned -> cosign never asked to verify a tag" "$(cat "$VRI/cosign.log")" ""

# #557: run_sourced disables errexit (`set +e`, right after sourcing) for every test above, which
# happens to mask a real bug: the bare `sha="$(compose_pinned_digest ...)"` assignment aborts under
# pithead's own `set -Eeuo pipefail` BEFORE the crafted error() above ever runs, so a real invocation
# got a silent abort instead of the "not digest-pinned" diagnostic. Reproduce with errexit left ON —
# source directly and call the function, no run_sourced/`set +e`.
# shellcheck disable=SC1090  # dynamic source: the script under test
out557_vri="$(
    (
        cd "$UNPINNED" || exit 1
        PATH="$VRI/bin:/usr/bin:/bin"
        source "$STACK" 2>/dev/null
        verify_release_images
    ) 2>&1
)"
assert_rc "un-pinned + key, real errexit -> still aborts (#557)" "$?" "1"
assert_contains "un-pinned + key, real errexit -> crafted message still reaches the operator (#557)" \
    "$out557_vri" "not digest-pinned"

# Source checkout: locally built images are unsigned by design — skipped, silently and completely.
mkdir -p "$VRI/dashboard"
touch "$VRI/dashboard/Dockerfile"
: >"$VRI/cosign.log"
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_RC=1 COSIGN_LOG="$VRI/cosign.log" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "source checkout -> verification skipped" "$?" "0"
assert_eq "source checkout -> cosign never invoked" "$(cat "$VRI/cosign.log")" ""
rm -rf "$VRI/build"

echo "== unit: cosign_container_path maps host paths into the verifier's mount (#1072) =="
# The verifier container sees the install dir at /w, so every file argument has to be renamed into
# that mount. The refusal case is the one that matters: both callers report a cosign failure as a
# SIGNATURE failure, so a path this function got wrong would read as a tampered download and burn a
# genuine release. It must fail rather than emit a path the mount does not cover.
CCP="$SANDBOX/ccp"
mkdir -p "$CCP/data/control/staged"
touch "$CCP/cosign.pub" "$CCP/data/control/staged/.abc.tar.gz"
assert_eq "file beside pithead -> /w/<name>" \
    "$(run_sourced "$CCP" cosign_container_path "$CCP/cosign.pub")" "/w/cosign.pub"
assert_eq "staged bundle -> /w/<relative dirs>/<name>" \
    "$(run_sourced "$CCP" cosign_container_path "$CCP/data/control/staged/.abc.tar.gz")" \
    "/w/data/control/staged/.abc.tar.gz"
# The `current -> pithead-vX.Y.Z` layout: CONTROL_DIR in .env can name the same file through the
# symlink while the runner's cwd is the physical dir. Canonicalizing both sides is what makes these
# agree — a plain "${path#$PWD/}" prefix strip silently does not, and would fail closed on prod.
ln -sfn "$CCP" "$SANDBOX/ccp-current"
assert_eq "same file reached via the current symlink still resolves" \
    "$(run_sourced "$CCP" cosign_container_path "$SANDBOX/ccp-current/data/control/staged/.abc.tar.gz")" \
    "/w/data/control/staged/.abc.tar.gz"
run_sourced "$CCP" cosign_container_path "$SANDBOX/outside.txt" >/dev/null 2>&1
assert_rc "a path outside the install dir is refused, not guessed at" "$?" "1"
run_sourced "$CCP" cosign_container_path "/etc/hosts" >/dev/null 2>&1
assert_rc "an absolute path elsewhere on the box is refused" "$?" "1"
