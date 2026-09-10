# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Release-PUBLISH domain (#1105 Phase 1): what a cut DOES against a registry — the GHCR
# read-after-push retry, the release-toolchain preflight, release-smoke's upgraded-install
# resolution, pull-vs-build mode detection, and the bundle's macOS-xattr hygiene guard. Split from
# test-release.sh, which keeps the side-effect-free helpers. Sourced by tests/stack/run.sh after it.
#
# The four script paths are re-derived here rather than inherited from test-release.sh, the same
# reason test-release-signing.sh re-derives its own: a fragment that depends on an earlier
# fragment's variables breaks silently when the suite is reordered, and `source "$REL" 2>/dev/null`
# hides exactly that failure as a pile of "command not found".
REL="$ROOT/scripts/release/release.sh"
REL_IMAGES="$ROOT/scripts/release/images.sh"
REL_BUNDLE="$ROOT/scripts/release/bundle.sh"
STACK_VERSION="v$(cat "$ROOT/VERSION")"
echo "== unit: release.sh registry read retries GHCR read-after-push lag (#429) =="
# manifest_digest reads a tag GHCR just accepted, which can 404 or serve a STALE digest for a few
# seconds (read-after-push lag) — this killed stage-4 digest capture twice on the v1.3.1 cut. So the
# retry is not only for empty reads: it loops until the EXPECTED digest appears, and the counter
# proves it stayed bounded. Backoff is forced to 0 to keep the test instant.
RETRY_CNT="$SANDBOX/inspect.count"
# shellcheck disable=SC1090,SC2034  # dynamic source; REGISTRY_READ_* are read by the sourced retry helper
retry_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    REGISTRY_READ_BACKOFF=0
    printf 0 >"$RETRY_CNT"
    buildx_inspect() {
        local n
        n=$(($(cat "$RETRY_CNT") + 1))
        printf '%s' "$n" >"$RETRY_CNT"
        [ "$n" -lt 3 ] && {
            printf 'Name: x\nDigest: sha256:%064d\n' 2
            return
        }                                          # attempts 1 and 2 are stale
        printf 'Name: x\nDigest: sha256:%064d\n' 1 # attempt 3 resolves
    }
    REGISTRY_READ_EXPECT_DIGEST=sha256:$(printf '%064d' 1)
    printf 'DIGEST=%s ATTEMPTS=%s\n' "$(manifest_digest some:tag)" "$(cat "$RETRY_CNT")"
)"
assert_contains "manifest_digest resolves after transient GHCR failures" "$retry_out" "DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000001"
assert_contains "retried until the read succeeded (3 attempts)" "$retry_out" "ATTEMPTS=3"
# Genuinely-missing image: after the retries exhaust, manifest_digest stays empty so the caller's
# `[ -n "$digest" ] || die` still stops the release (a missing image must not silently pass).
# shellcheck disable=SC1090,SC2034  # dynamic source; REGISTRY_READ_* are read by the sourced retry helper
exhaust_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    REGISTRY_READ_BACKOFF=0
    REGISTRY_READ_RETRIES=3
    buildx_inspect() { return 1; } # GHCR never makes it readable
    digest="$(manifest_digest gone:tag)"
    [ -n "$digest" ] || echo "DIED-EMPTY"
)"
assert_contains "exhausted retries -> empty digest (caller dies)" "$exhaust_out" "DIED-EMPTY"
# The smoke stage's raw manifest read has the same read-after-push exposure — wire it through the retry.
assert_contains "smoke stage reads the captured digest via retry_registry_read (#429)" \
    "$(cat "$REL_IMAGES")" 'retry_registry_read buildx_inspect "$digest" --raw'

# #557: the test above disables errexit (`set +eu`, right after sourcing) to observe the bare helper
# in isolation, which happens to mask a real bug in stage_push itself: the bare
# `digest="$(manifest_digest ...)"` assignment aborts under release.sh's own `set -euo pipefail`
# BEFORE the crafted die() ever runs, so a real release run got a silent abort instead of a diagnosed
# digest-read failure. Reproduce with errexit left ON, driving the REAL stage_push (not the bare
# helper) so the actual call site is exercised.
# shellcheck disable=SC1090,SC2034  # dynamic source; the globals are consumed inside stage_push
stage_push_out="$(
    (
        cd "$ROOT" || exit 1
        set --
        source "$REL" 2>/dev/null
        DRY_RUN=0
        IMAGES=(tor)
        REGISTRY="ghcr.io/test"
        REGISTRY_READ_RETRIES=1
        REGISTRY_READ_BACKOFF=0
        WORKDIR="$SANDBOX/stagepush557"
        mkdir -p "$WORKDIR"
        buildx_inspect() { return 1; } # every registry read fails -> retries exhaust
        stage_push
    ) 2>&1
)"
assert_rc "stage_push, real errexit: retries-exhausted digest read still aborts (#557)" "$?" "1"
assert_contains "stage_push, real errexit: crafted die() reaches the operator (#557)" \
    "$stage_push_out" "Could not read the pushed manifest digest"
# #557: main()'s --resume-promote branch has the exact same shape (a second, separately-written
# instance of the bug — found in review, not part of the original 3 sites). Drive the real `main`
# (preflight/ghcr_login stubbed no-op) with RESUME_PROMOTE=1 and errexit left ON.
# shellcheck disable=SC1090,SC2034  # dynamic source; the globals are consumed inside main
resume_out="$(
    (
        cd "$ROOT" || exit 1
        set --
        source "$REL" 2>/dev/null
        preflight() { :; }
        ghcr_login() { :; }
        promote() { :; }
        sign_images() { :; }
        publish() { :; }
        DRY_RUN=0
        RESUME_PROMOTE=1
        IMAGES=(tor)
        TAG="v9.9.9"
        STAGING_TAG="v9.9.9-rc.1"
        REGISTRY="ghcr.io/test"
        REGISTRY_READ_RETRIES=1
        REGISTRY_READ_BACKOFF=0
        buildx_inspect() { return 1; } # every registry read fails -> retries exhaust
        main
    ) 2>&1
)"
assert_rc "--resume-promote, real errexit: retries-exhausted digest read still aborts (#557)" "$?" "1"
assert_contains "--resume-promote, real errexit: crafted die() reaches the operator (#557)" \
    "$resume_out" "Cannot resolve a staged digest"
echo "== unit: release.sh preflight checks the lint toolchain (#426) =="
# A reimaged release box loses shellcheck/shfmt/node/uv — the v1.3.0 cut died ~1 min in mid-gate with a
# bare `shellcheck: not found`. check_release_toolchain must fail fast BEFORE building, naming the tool
# and the provisioning doc. Point PATH at a sandbox of stub tools so the host's real PATH doesn't decide.
RTB="$SANDBOX/release-tools"
mkdir -p "$RTB"
for t in shellcheck shfmt node npx uv uvx; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$RTB/$t"
    chmod +x "$RTB/$t"
done
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    PATH="$RTB" check_release_toolchain >/dev/null 2>&1
)
assert_rc "full toolchain present -> preflight passes" "$?" "0"
rm -f "$RTB/shfmt" # simulate a reimaged box missing one tool
# shellcheck disable=SC1090
tc_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    PATH="$RTB" check_release_toolchain 2>&1
)"
tc_rc=$?
assert_rc "missing tool -> preflight fails fast (rc 1)" "$tc_rc" "1"
assert_contains "the missing tool is named" "$tc_out" "shfmt"
assert_contains "error points at the provisioning doc" "$tc_out" "release-server.md"
echo "== unit: release-smoke resolves the upgraded install at ASSERT time (#1068) =="
# The #59 upgrade never rewrites the old install in place — it extracts a fresh pithead-v<new> and
# repoints `current`, which is what makes rollback possible. So asserting on the directory the run
# was POINTED at could only pass if the upgrade had overwritten the previous install: a correct
# upgrade reported as a failure, on the documented final gate of a release. MUTATION PROOF: return
# the given path unresolved and both "lands on" assertions go red.
SMK="$SANDBOX/smoke1068"
SMOKE_SH="$ROOT/scripts/release/release-smoke.sh"
mkdir -p "$SMK/pithead-v1.18.1" "$SMK/pithead-v1.19.0"
printf '1.18.1\n' >"$SMK/pithead-v1.18.1/VERSION"
printf '1.19.0\n' >"$SMK/pithead-v1.19.0/VERSION"
ln -sfn "$SMK/pithead-v1.19.0" "$SMK/current"
smoke_resolve() { # <dir-as-given>
    (
        _arg="$1"          # saved before `set --`, which release-smoke's own arg parser needs empty
        cd "$ROOT" || exit # its top level insists on a git repo, like the real invocation
        set --
        # Sourced through a variable, never a literal path: shellcheck follows a literal that names
        # another file in the same invocation, and release-smoke pulls in release.sh, whose
        # `local tool missing=()` then collides with this file's own scalar `missing` (SC2178).
        # shellcheck disable=SC1090
        source "$SMOKE_SH" 2>/dev/null
        set +eu
        upgraded_install_dir "$_arg"
    )
}
# Handed the previous VERSIONED dir — the shape that produced the false red. It is unchanged by
# design, so the answer has to come from the `current` beside it.
assert_eq "a versioned dir resolves to where the upgrade actually landed" \
    "$(tr -d '[:space:]' <"$(smoke_resolve "$SMK/pithead-v1.18.1")/VERSION")" "1.19.0"
# Handed the SYMLINK — resolved now, after the upgrade moved it. This is why the v1.19.2 cut did
# not hit the false red, and it must keep working.
assert_eq "the current symlink resolves to the new install" \
    "$(tr -d '[:space:]' <"$(smoke_resolve "$SMK/current")/VERSION")" "1.19.0"
# Nothing moved: a box that is already on the target must resolve to itself, not wander off.
ln -sfn "$SMK/pithead-v1.18.1" "$SMK/current"
assert_eq "with current pointing at it, the same dir resolves to itself" \
    "$(smoke_resolve "$SMK/pithead-v1.18.1")" "$SMK/pithead-v1.18.1"
# NOTE, measured rather than assumed: replacing the `readlink -f` with the raw argument leaves all
# three assertions above GREEN. The sibling lookup is what fixes the false red; the readlink only
# normalises the path that lands in the pass and failure messages. Recorded here so the next reader
# does not mistake it for a covered behaviour.
rm -rf "$SMK"
unset SMK SMOKE_SH
echo "== unit: pull-vs-build mode (#44) =="
# is_source_checkout / resolve_pull_policy / STACK_VERSION key off whether the image build CONTEXTS
# (Dockerfiles) are present: a source checkout builds locally (:dev, --pull never); a release bundle
# (only build/tari/ + VERSION) pulls (:vX.Y.Z, --pull missing). Two scratch dirs stand in for each.
SRCM="$SANDBOX/srcmode"
mkdir -p "$SRCM/dashboard"
: >"$SRCM/dashboard/Dockerfile"
printf '0.1.0\n' >"$SRCM/VERSION"
RELM="$SANDBOX/relmode"
mkdir -p "$RELM/build/tari"
printf '0.1.0\n' >"$RELM/VERSION"
# shellcheck disable=SC1090
(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    is_source_checkout
)
assert_rc "is_source_checkout true with a Dockerfile" "$?" "0"
# shellcheck disable=SC1090
(
    cd "$RELM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    is_source_checkout
)
assert_rc "is_source_checkout false without a Dockerfile" "$?" "1"
# shellcheck disable=SC1090
assert_eq "pull policy: source -> never" "$(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    resolve_pull_policy
)" "never"
# shellcheck disable=SC1090
assert_eq "pull policy: release -> missing" "$(
    cd "$RELM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    resolve_pull_policy
)" "missing"
# shellcheck disable=SC1090
assert_eq "pull policy: PITHEAD_PULL override" "$(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    PITHEAD_PULL=always resolve_pull_policy
)" "always"
# shellcheck disable=SC1090
assert_eq "STACK_VERSION dev in a source checkout" "$(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    export_build_provenance
    printf '%s' "$STACK_VERSION"
)" "dev"
# shellcheck disable=SC1090
assert_eq "STACK_VERSION v0.1.0 in a release bundle" "$(
    cd "$RELM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    export_build_provenance
    printf '%s' "$STACK_VERSION"
)" "v0.1.0"
echo "== release: install bundle is free of macOS xattr pax headers (#252) =="
# Static guard: make_bundle must keep `--no-xattrs` AND the post-bundle xattr assertion, so the
# fix can't be silently reverted in a future edit.
assert_contains "release.sh tars the bundle with --no-xattrs" \
    "$(grep -E '^[[:space:]]*tar .*--no-xattrs' "$REL_BUNDLE" || true)" "--no-xattrs"
assert_contains "release.sh guards the bundle against xattr pax headers" \
    "$(cat "$REL_BUNDLE")" "LIBARCHIVE.xattr"
# Functional: this platform's tar must actually honour --no-xattrs (the guard's whole premise).
# Tar a file that carries an xattr where we can set one (macOS: xattr -w / Linux: setfattr; a
# no-op elsewhere), and assert no LIBARCHIVE.xattr/SCHILY.xattr pax header survives — the exact
# check release.sh runs. Reproduces #252 on macOS; a clean no-op on GNU tar.
mk_tmpdir RELTMP
mkdir -p "$RELTMP/pithead"
echo hi >"$RELTMP/pithead/f"
xattr -w com.test val "$RELTMP/pithead/f" 2>/dev/null ||
    setfattr -n user.test -v val "$RELTMP/pithead/f" 2>/dev/null || true
tar --no-xattrs -czf "$RELTMP/b.tar.gz" -C "$RELTMP" pithead 2>/dev/null
if grep -qa -e 'LIBARCHIVE.xattr' -e 'SCHILY.xattr' <(gzip -dc "$RELTMP/b.tar.gz" 2>/dev/null); then
    bad "tar --no-xattrs yields an xattr-free bundle" "xattr pax headers present despite --no-xattrs"
else
    ok "tar --no-xattrs yields an xattr-free bundle"
fi
rm -rf "$RELTMP"
