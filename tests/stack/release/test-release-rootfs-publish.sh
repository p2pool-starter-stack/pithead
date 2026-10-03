# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Release rootfs publish tests (#1353): the debug-key guard, the producer's digest handoff and the
# os-rootfs branch of the staging smoke test. Paths are re-derived so suite order does not matter.
REL="$ROOT/scripts/release/release.sh"
echo "== unit: release rootfs publish guard refuses the debug SSH key (#1353) =="
ROOTFS_GUARD="$SANDBOX/rootfs-publish-guard"
mkdir -p "$ROOTFS_GUARD/release/etc" "$ROOTFS_GUARD/debug/etc" "$ROOTFS_GUARD/debug/root/.ssh"
mkdir -p "$ROOTFS_GUARD/debug-link/etc" "$ROOTFS_GUARD/debug-link/root" "$ROOTFS_GUARD/debug-link/keys"
printf 'release\n' >"$ROOTFS_GUARD/release/etc/pithead-variant"
printf 'release\n' >"$ROOTFS_GUARD/debug/etc/pithead-variant"
printf 'ssh-ed25519 fixture\n' >"$ROOTFS_GUARD/debug/root/.ssh/authorized_keys"
printf 'release\n' >"$ROOTFS_GUARD/debug-link/etc/pithead-variant"
printf 'ssh-ed25519 fixture\n' >"$ROOTFS_GUARD/debug-link/keys/authorized_keys"
ln -s ../keys "$ROOTFS_GUARD/debug-link/root/.ssh"
tar -cf "$ROOTFS_GUARD/release.tar" -C "$ROOTFS_GUARD/release" etc
tar -cf "$ROOTFS_GUARD/debug.tar" -C "$ROOTFS_GUARD/debug" etc root
tar -cf "$ROOTFS_GUARD/debug-dot.tar" -C "$ROOTFS_GUARD/debug" .
tar --transform='s|root/.ssh/authorized_keys|root//.ssh/authorized_keys|' \
    -cf "$ROOTFS_GUARD/debug-double.tar" -C "$ROOTFS_GUARD/debug" etc root
tar --transform='s|root/.ssh/authorized_keys|root/./.ssh/authorized_keys|' \
    -cf "$ROOTFS_GUARD/debug-inner-dot.tar" -C "$ROOTFS_GUARD/debug" etc root
tar --transform='s|root/.ssh/authorized_keys|.//root/.ssh/authorized_keys|' \
    -cf "$ROOTFS_GUARD/debug-dot-absolute.tar" -C "$ROOTFS_GUARD/debug" etc root
tar --transform='s|root/.ssh/authorized_keys|//root/.ssh/authorized_keys|' \
    -cf "$ROOTFS_GUARD/debug-absolute.tar" -C "$ROOTFS_GUARD/debug" etc root
tar -cf "$ROOTFS_GUARD/debug-link.tar" -C "$ROOTFS_GUARD/debug-link" etc root keys
mkdir -p "$ROOTFS_GUARD/debug-dir/etc" "$ROOTFS_GUARD/debug-dir/root/.ssh/authorized_keys"
printf 'release\n' >"$ROOTFS_GUARD/debug-dir/etc/pithead-variant"
printf 'ssh-ed25519 fixture\n' >"$ROOTFS_GUARD/debug-dir/root/.ssh/authorized_keys/root"
tar -cf "$ROOTFS_GUARD/debug-dir.tar" -C "$ROOTFS_GUARD/debug-dir" etc root
rootfs_guard() {
    local tarball="$1"
    (
        cd "$ROOT" || exit
        set --
        # shellcheck disable=SC1090
        source "$REL" 2>/dev/null
        set +eu
        verify_release_rootfs_tar "$tarball"
    )
}
rootfs_guard "$ROOTFS_GUARD/release.tar"
assert_rc "a release rootfs with no debug key passes the push guard" "$?" "0"
rootfs_guard_out="$(rootfs_guard "$ROOTFS_GUARD/debug.tar" 2>&1)"
assert_rc "a debug rootfs carrying the SSH key is refused before push" "$?" "2"
assert_contains "the refusal names the debug SSH key" "$rootfs_guard_out" "refusing a rootfs carrying the debug SSH key"
TAR_OPTIONS='--exclude=*/authorized_keys' rootfs_guard "$ROOTFS_GUARD/debug.tar" >/dev/null 2>&1
assert_rc "inherited tar exclusions cannot hide the debug SSH key" "$?" "2"
mkdir "$ROOTFS_GUARD/extracted"
# shellcheck disable=SC1090
(cd "$ROOT" && set -- && source "$REL" 2>/dev/null && TAR_OPTIONS='--transform=s#etc/pithead-variant#root/.ssh/authorized_keys#' extract_rootfs_tar "$ROOTFS_GUARD/release.tar" "$ROOTFS_GUARD/extracted")
assert_eq "inherited tar transforms cannot create an authorized_keys file" "$([ -e "$ROOTFS_GUARD/extracted/root/.ssh/authorized_keys" ] && echo yes || echo no)" "no"
assert_eq "the hermetic extraction keeps the original member" "$([ -e "$ROOTFS_GUARD/extracted/etc/pithead-variant" ] && echo yes || echo no)" "yes"
for unsafe_tar in debug-dot debug-double debug-inner-dot debug-dot-absolute debug-absolute debug-link debug-dir; do
    rootfs_guard "$ROOTFS_GUARD/$unsafe_tar.tar" >/dev/null 2>&1
    assert_rc "an unsafe debug-key member is refused" "$?" "2"
done
unset -f rootfs_guard
# Drive the producer with a stubbed export and registry write so ordering mutations fail.
drive_rootfs_build() { # <fixture-tar> <push-log>
    local source_tar="$1" push_log="$2"
    (
        export SOURCE_TAR="$source_tar" PUSH_LOG="$push_log"
        cd "$ROOT" || exit
        set --
        # shellcheck disable=SC1090
        source "$REL" 2>/dev/null
        # The producer writes os/build/pithead-root.tar relative to the cwd. Drive it in a scratch
        # tree: os/build is git-ignored and absent from a clean checkout (the real build-image.sh
        # creates it), and a developer's own export must not be clobbered by a test run.
        rm -rf "$SANDBOX/rootfs-producer"
        mkdir -p "$SANDBOX/rootfs-producer/os/build"
        cd "$SANDBOX/rootfs-producer" || exit
        DRY_RUN=0
        # shellcheck disable=SC2034  # consumed by the dynamically sourced build_rootfs_image
        PLATFORMS=linux/amd64
        # shellcheck disable=SC2034  # consumed by the dynamically sourced build_rootfs_image
        STAGING_TAG=v2.0.0-rc.1
        rootfs_tar=os/build/pithead-root.tar
        manifest_digest() { printf 'sha256:%064d\n' 4; }
        run() {
            if [[ "$*" == *os/build-image.sh ]]; then
                printf '%s\n' "$*" >"$PUSH_LOG.build"
                cp "$SOURCE_TAR" "$rootfs_tar"
            elif [ "$1 $2" = "docker push" ]; then
                printf 'push=%s final=%s temporary=%s\n' "$3" \
                    "$([ -e "$rootfs_tar.sha256" ] && echo yes || echo no)" \
                    "$([ "$(cat "$rootfs_tar.sha256.tmp")" = "$(sha256sum "$rootfs_tar" | awk '{print $1}')" ] && echo exact || echo bad)" >>"$PUSH_LOG"
                [ "${PUSH_FAIL:-0}" -eq 0 ]
            else
                command "$@"
            fi
        }
        # The subshell's status must be the producer's alone: a trailing `[ ... ] &&` returns 1
        # whenever no handoff was written, which would mask a producer that swallowed a failed push.
        build_rootfs_image || exit $?
        if [ -s "$rootfs_tar.sha256" ]; then printf 'finalized=yes\n' >>"$PUSH_LOG"; fi
    )
}
PUSH_LOG="$ROOTFS_GUARD/pushes"
: >"$PUSH_LOG"
drive_rootfs_build "$ROOTFS_GUARD/debug-dot.tar" "$PUSH_LOG" >/dev/null 2>&1
assert_rc "the producer refuses a keyed export" "$?" "1"
assert_eq "the keyed export is refused before any registry push" "$(wc -l <"$PUSH_LOG" | tr -d ' ')" "0"
drive_rootfs_build "$ROOTFS_GUARD/release.tar" "$PUSH_LOG" >/dev/null 2>&1
assert_rc "the producer accepts a release export" "$?" "0"
assert_contains "the push starts with only a temporary digest handoff" "$(cat "$PUSH_LOG")" \
    "final=no temporary=exact"
assert_contains "a successful push atomically finalizes the digest handoff" "$(cat "$PUSH_LOG")" \
    "finalized=yes"
# The five images exist only under the staging tag at stage 3; vX.Y.Z is made at promotion. Pinning from
# vX.Y.Z here failed every real cut since #2241 (2026-09-21) at "could not resolve an immutable digest".
assert_contains "the rootfs build pins the five images from the staging tag" "$(cat "$PUSH_LOG.build")" \
    "PITHEAD_PIN_TAG=v2.0.0-rc.1"
: >"$PUSH_LOG"
PUSH_FAIL=1 drive_rootfs_build "$ROOTFS_GUARD/release.tar" "$PUSH_LOG" >/dev/null 2>&1
assert_rc "a failed rootfs registry push fails the producer" "$?" "1"
assert_contains "a failed push never exposes the final digest handoff" "$(cat "$PUSH_LOG")" \
    "final=no temporary=exact"
assert_not_contains "a failed push does not finalize the digest handoff" "$(cat "$PUSH_LOG")" \
    "finalized=yes"
unset -f drive_rootfs_build
# A private first push would pass authenticated reads but leave the anonymous sweep UNCHECKED.
# shellcheck disable=SC1090
anonymous_digest="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    curl() {
        case "$*" in
        *'https://ghcr.io/token?scope='*) printf '{"token":"fixture"}\n' ;;
        *) printf 'Docker-Content-Digest: sha256:%064d\r\n' 7 ;;
        esac
    }
    anonymous_ghcr_digest ghcr.io/p2pool-starter-stack/pithead-os-rootfs v2.0.0
)"
assert_eq "the public-package check resolves the rootfs anonymously" "$anonymous_digest" \
    "sha256:$(printf '%064d' 7)"
# Drive the real smoke_test on the os-rootfs entry with stubbed docker and registry reads.
# shellcheck disable=SC1090,SC2034,SC2329  # dynamic source; globals and stubs are used by the sourced smoke_test
rootfs_smoke() { # <export-tar> <inspect-output> <anonymous-digest> [export-rc]
    (
        export SMOKE_TAR="$1" SMOKE_INSPECT="$2" SMOKE_ANON="$3" SMOKE_EXPORT_RC="${4:-0}"
        cd "$ROOT" || exit
        set --
        source "$REL" 2>/dev/null
        set +eu
        DRY_RUN=0 SKIP_SMOKE=0 PUBLISHED_IMAGES=(os-rootfs) REGISTRY=ghcr.io/test
        PLATFORMS=linux/amd64 STAGING_TAG=v9.9.9-rc.1 STACK_VERSION=v9.9.9 RELEASE_SMOKE_CMD=
        WORKDIR="$SANDBOX/rootfs-smoke"
        mkdir -p "$WORKDIR"
        printf 'ghcr.io/test/pithead-os-rootfs@sha256:%064d\n' 7 >"$WORKDIR/digest.os-rootfs"
        anonymous_ghcr_digest() { printf '%s' "$SMOKE_ANON"; }
        docker() {
            case "$1" in
            create) echo cid ;;
            export)
                [ "$SMOKE_EXPORT_RC" -eq 0 ] || return "$SMOKE_EXPORT_RC"
                cp "$SMOKE_TAR" "$3"
                ;;
            inspect) printf '%s\n' "$SMOKE_INSPECT" ;;
            esac
            return 0
        }
        smoke_test
    ) 2>&1
}
smoke_ok="v9.9.9 linux/amd64"
smoke_digest="sha256:$(printf '%064d' 7)"
rootfs_smoke "$ROOTFS_GUARD/release.tar" "$smoke_ok" "$smoke_digest" >/dev/null
assert_rc "rootfs smoke passes a public release export with matching label and platform" "$?" "0"
smoke_out="$(rootfs_smoke "$ROOTFS_GUARD/debug-dot.tar" "$smoke_ok" "$smoke_digest")"
assert_rc "rootfs smoke refuses a pulled image carrying a root SSH key" "$?" "1"
assert_contains "the keyed pull is refused by the shell-less check" "$smoke_out" "not a shell-less release rootfs"
smoke_out="$(rootfs_smoke "$ROOTFS_GUARD/release.tar" "$smoke_ok" "$smoke_digest" 7)"
assert_rc "rootfs smoke refuses an image it cannot export" "$?" "1"
smoke_out="$(rootfs_smoke "$ROOTFS_GUARD/release.tar" "v0.0.1 linux/amd64" "$smoke_digest")"
assert_rc "rootfs smoke refuses a wrong version label" "$?" "1"
assert_contains "the wrong label is named" "$smoke_out" "reports version/platform 'v0.0.1 linux/amd64'"
smoke_out="$(rootfs_smoke "$ROOTFS_GUARD/release.tar" "v9.9.9 linux/arm64" "$smoke_digest")"
assert_rc "rootfs smoke refuses a wrong platform" "$?" "1"
assert_contains "the wrong platform is named" "$smoke_out" "reports version/platform 'v9.9.9 linux/arm64'"
smoke_out="$(rootfs_smoke "$ROOTFS_GUARD/release.tar" "$smoke_ok" "")"
assert_rc "rootfs smoke refuses a private package (anonymous read does not resolve)" "$?" "1"
assert_contains "the private package is named" "$smoke_out" "New GHCR packages default to private"
smoke_out="$(rootfs_smoke "$ROOTFS_GUARD/release.tar" "$smoke_ok" "sha256:$(printf '%064d' 8)")"
assert_rc "rootfs smoke refuses an anonymous digest that differs from the captured one" "$?" "1"
unset -f rootfs_smoke
