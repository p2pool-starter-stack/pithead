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
