# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== unit: release notes include the tagged version's known issues =="
release_notes_fixture="$SANDBOX/release-notes"
mkdir -p "$release_notes_fixture"
cat >"$release_notes_fixture/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## [Unreleased]

Future changes must not be published yet.

## [2.0.1] - 2026-10-10

A newer release must not be selected by position.

## [2.0.0] - 2026-10-03

### Known issues

- [#2436](https://github.com/p2pool-starter-stack/pithead/issues/2436)
- [#3166](https://github.com/p2pool-starter-stack/pithead/issues/3166)

## [1.20.0] - 2026-09-01

Old changes must not leak into this release.
CHANGELOG
release_notes_extract() {
    (
        cd "$release_notes_fixture" || exit
        # shellcheck source=scripts/release/bundle.sh
        source "$ROOT/scripts/release/bundle.sh"
        TAG="$1" changelog_notes
    )
}
release_notes_out="$(release_notes_extract v2.0.0)"
assert_rc "release notes extract the tagged changelog entry" "$?" "0"
assert_contains "release notes include the tagged version heading" "$release_notes_out" '## [2.0.0]'
assert_contains "release notes include the Known issues heading" "$release_notes_out" '### Known issues'
assert_contains "release notes include the silent boot-gate issue link" "$release_notes_out" \
    '[#2436](https://github.com/p2pool-starter-stack/pithead/issues/2436)'
assert_contains "release notes include the Tor control prerequisite issue link" "$release_notes_out" \
    '[#3166](https://github.com/p2pool-starter-stack/pithead/issues/3166)'
assert_not_contains "release notes exclude pending changes" "$release_notes_out" 'Future changes'
assert_not_contains "release notes exclude newer releases" "$release_notes_out" 'A newer release'
assert_not_contains "release notes stop before older releases" "$release_notes_out" 'Old changes'
release_notes_out="$(release_notes_extract v2.0.2 2>"$release_notes_fixture/warning")"
assert_rc "a missing release entry uses a successful fallback" "$?" "0"
assert_contains "a missing entry warns on stderr" "$(cat "$release_notes_fixture/warning")" 'release v2.0.2'
assert_contains "a missing entry selects the first non-Unreleased section" "$release_notes_out" '## [2.0.1]'
assert_not_contains "fallback notes exclude pending changes" "$release_notes_out" 'Future changes'
assert_not_contains "fallback notes stop before the next release" "$release_notes_out" '### Known issues'
# Dots in a version are literal, not regular-expression wildcards.
sed 's/\[2.0.0\]/[2x0x0]/' "$release_notes_fixture/CHANGELOG.md" >"$release_notes_fixture/other.md"
mv "$release_notes_fixture/other.md" "$release_notes_fixture/CHANGELOG.md"
release_notes_out="$(release_notes_extract v2.0.0 2>"$release_notes_fixture/warning")"
assert_contains "literal version mismatch uses the fallback" "$release_notes_out" '## [2.0.1]'
assert_contains "version matching does not treat dots as wildcards" "$(cat "$release_notes_fixture/warning")" 'release v2.0.0'
printf '## [2.0.0-rc.1]\n\nCandidate notes\n' >"$release_notes_fixture/CHANGELOG.md"
assert_contains "release notes support prerelease tags" "$(release_notes_extract v2.0.0-rc.1)" 'Candidate notes'
rm "$release_notes_fixture/CHANGELOG.md"
release_notes_out="$(release_notes_extract v2.0.0 2>&1)"
assert_rc "a missing changelog preserves successful fallback" "$?" "0"
assert_eq "a missing changelog emits the release title" "$release_notes_out" 'Pithead v2.0.0'
rm -rf "$release_notes_fixture"
unset release_notes_fixture release_notes_out
unset -f release_notes_extract

echo "== unit: release records and attaches the installed OS packages (#4254) =="
os_pkg_dir="$SANDBOX/os-packages"
mkdir -p "$os_pkg_dir/bin" "$os_pkg_dir/work"
printf 'ID=alpine\nVERSION_ID=3.24.1\n' >"$os_pkg_dir/os-release"
printf 'P:musl\nV:1.2.5-r10\no:musl\n\nP:libcrypto3\nV:3.5.4-r0\no:openssl\n' >"$os_pkg_dir/installed"
cat >"$os_pkg_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in
create) case "$*" in *"${OS_PKG_FAIL:-none}"*) exit 1 ;; esac; echo cid ;;
cp)
    case "${*: -2:1}" in
    cid:/etc/os-release) cp "$OS_PKG_DIR/os-release" "${*: -1}" ;;
    cid:/lib/apk/db/installed) cp "$OS_PKG_DIR/installed" "${*: -1}" ;;
    *) exit 1 ;;
    esac
    ;;
esac
DOCKER
chmod +x "$os_pkg_dir/bin/docker"
os_pkg_capture() {
    local fail="${1:-none}"
    (
        cd "$ROOT" || exit
        set --
        # shellcheck source=scripts/release/release.sh
        source "$REL" 2>/dev/null
        set +eu
        export OS_PKG_DIR="$os_pkg_dir" OS_PKG_FAIL="$fail" PATH="$os_pkg_dir/bin:$PATH"
        WORKDIR="$os_pkg_dir/work" DRY_RUN=0 TAG=v9.9.9 STACK_VERSION=9.9.9 GIT_COMMIT=abc BUILD_DATE=now
        for s in "${PUBLISHED_IMAGES[@]}"; do set_digest "$s" "ghcr.io/test/pithead-$s@sha256:1"; done
        capture_packages >/dev/null || exit
        write_manifest "$WORKDIR/manifest.md" >/dev/null
    )
}
os_pkg_capture
assert_rc "capture_packages records every published image" "$?" "0"
assert_eq "the package list has one line per image and source package" \
    "$(grep -c . "$os_pkg_dir/work/os-packages.txt")" "12"
assert_contains "each line names the image, OSV ecosystem, source package and version" \
    "$(cat "$os_pkg_dir/work/os-packages.txt")" "os-rootfs Alpine:v3.24 openssl 3.5.4-r0"
assert_contains "the manifest names the attached package asset" \
    "$(cat "$os_pkg_dir/work/manifest.md")" 'Attached as `os-packages-v9.9.9.txt`'
assert_contains "the manifest counts each image's source packages" \
    "$(cat "$os_pkg_dir/work/manifest.md")" "- tor: 2 source packages (Alpine:v3.24)"
os_pkg_err="$(os_pkg_capture pithead-os-rootfs 2>&1)"
os_pkg_rc=$?
assert_eq "a failed capture stops the release" "$os_pkg_rc" "1"
assert_contains "a failed capture names the image" "$os_pkg_err" \
    "Could not record the installed OS packages of ghcr.io/test/pithead-os-rootfs@sha256:1"
os_pkg_run="$(
    cd "$ROOT" || exit
    set --
    # shellcheck source=scripts/release/release.sh
    source "$REL" 2>/dev/null
    set +eu
    WORKDIR="$os_pkg_dir/work" DRY_RUN=0 DRAFT=0 COSIGN_ENABLED=0 TAG=v9.9.9 STACK_VERSION=9.9.9 GIT_COMMIT=abc BUILD_DATE=now
    make_bundle() { : >"$1"; }
    append_bundle_sha256() { :; }
    changelog_notes() { :; }
    confirm() { return 0; }
    gh() { :; }
    run() { printf '%s\n' "$*"; }
    require_gated_commit() { :; }
    publish 2>/dev/null
)"
assert_contains "publish attaches the package list to the GitHub Release" "$os_pkg_run" \
    "release create v9.9.9 --title Pithead v9.9.9 --notes-file $os_pkg_dir/work/notes.md $os_pkg_dir/work/pithead.tar.gz $os_pkg_dir/work/ingredients-v9.9.9.md $os_pkg_dir/work/os-packages-v9.9.9.txt"
assert_eq "the attached list is the recorded list" \
    "$(cmp -s "$os_pkg_dir/work/os-packages.txt" "$os_pkg_dir/work/os-packages-v9.9.9.txt" && echo same)" "same"
os_pkg_err="$(
    cd "$ROOT" || exit
    set --
    # shellcheck source=scripts/release/release.sh
    source "$REL" 2>/dev/null
    set +eu
    WORKDIR="$os_pkg_dir/empty" DRY_RUN=0 TAG=v9.9.9 STACK_VERSION=9.9.9 GIT_COMMIT=abc BUILD_DATE=now
    mkdir -p "$WORKDIR"
    require_gated_commit() { :; }
    publish 2>&1 >/dev/null
)"
assert_eq "publish stops when no package list was recorded" "$?" "1"
assert_contains "publish names the missing package list" "$os_pkg_err" "refusing to publish without it"
rm -rf "$os_pkg_dir"
unset os_pkg_dir os_pkg_err os_pkg_rc os_pkg_run
unset -f os_pkg_capture
