# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Release toolchain and literal env loading; every driver starts a fresh shell with release.sh's flags.
REL="$ROOT/scripts/release/release.sh"
RT_BASH="$(command -v bash)"
RTB="$SANDBOX/release-tools"
RT_KEYS="$SANDBOX/release-env-keys"
RT_TOOLS="$SANDBOX/release-extra-tools"
RT_SENTINEL="release-env-sentinel-3446"
mkdir -p "$RTB" "$RT_KEYS" "$RT_TOOLS"
chmod 0755 "$RTB" "$RT_KEYS" "$RT_TOOLS"
ln -sf "$(command -v stat)" "$RTB/stat"
ln -sf "$(command -v id)" "$RTB/id"

rt_drive() {
    # A separate bash prevents run.sh's && source stanza from disabling errexit in the driven code.
    # shellcheck disable=SC1090,SC1091
    RT_REL="$REL" RT_BIN="$RTB" RT_KEYPATH="$RT_KEYS" RT_EXTRA="$RT_TOOLS" \
        "$RT_BASH" -c '
        set --
        source "$RT_REL"
        RELEASE_KEY_DIR="$RT_KEYPATH"
        unset PITHEAD_RELEASE_ENV BENCH_CI_APP_ID BENCH_CI_APP_SLUG RELEASE_INTEGRATION_ARGS RELEASE_TOOL_PATH
        export PATH="$RT_BIN"
        source /dev/stdin
    ' 2>&1
}

for t in shellcheck shfmt node npx uv uvx; do
    printf '#!/bin/sh\nexit 0\n' >"$RT_TOOLS/$t"
    chmod +x "$RT_TOOLS/$t"
done

echo "== unit: release.sh checks the run toolchain in real and dry runs (#426, #3446) =="
for dry in 0 1; do
    for skip in 0 1; do
        rt_out="$(
            rt_drive <<SH
DRY_RUN=$dry
SKIP_TESTS=$skip
require_release_toolchain
SH
        )"
        rt_rc=$?
        # MUTATION PROOF: unconditionally check tools and skip=1 fails; skip dry runs and dry=1 passes incorrectly.
        assert_rc "toolchain guard honors skip in real and dry runs" "$rt_rc" "$((1 - skip))"
        if [ "$skip" -eq 0 ]; then
            for t in shellcheck shfmt node npx uv uvx; do
                # MUTATION PROOF: stop after the first missing tool and later names disappear.
                assert_contains "every missing tool is named" "$rt_out" "$t"
            done
            # MUTATION PROOF: remove the effective PATH diagnostic.
            assert_contains "failure prints effective PATH" "$rt_out" "Effective PATH: $RTB"
            # MUTATION PROOF: restore the bypass hint in the error text.
            assert_not_contains "missing-tool error has no bypass hint" "$rt_out" "--skip-tests"
        fi
    done
    rt_out="$(
        rt_drive <<SH
DRY_RUN=$dry
SKIP_TESTS=0
RELEASE_TOOL_PATH="\$RT_EXTRA"
apply_release_path
require_release_toolchain
printf 'FIRST=%s\n' "\${PATH%%:*}"
/bin/sh -c 'command -v shfmt'
SH
    )"
    # MUTATION PROOF: keep the tools off PATH or skip the dry-run check.
    assert_rc "full toolchain present -> preflight passes" "$?" "0"
    for t in shellcheck shfmt node npx uv uvx; do
        # MUTATION PROOF: suppress the resolved-tool log.
        assert_contains "every resolved tool path is logged" "$rt_out" "$RT_TOOLS/$t"
    done
    # MUTATION PROOF: append RELEASE_TOOL_PATH rather than prepend it.
    assert_contains "tool directory is first on PATH" "$rt_out" "FIRST=$RT_TOOLS"
done
rt_out="$(
    rt_drive <<'SH'
export -n PATH
RELEASE_TOOL_PATH="$RT_EXTRA"
apply_release_path
/bin/sh -c 'command -v shfmt'
SH
)"
# MUTATION PROOF: remove export PATH from apply_release_path.
assert_eq "child inherits adjusted PATH" "$rt_out" "$RT_TOOLS/shfmt"

cp "$RT_TOOLS/"* "$RTB/"
rm "$RTB/shfmt"
rt_out="$(
    rt_drive <<'SH'
DRY_RUN=1
SKIP_TESTS=0
bash() { :; }
git() { printf '%s\n' "$ROOT_FOR_PREFLIGHT"; }
docker() { :; }
require_clean_release_tree() { :; }
ROOT_FOR_PREFLIGHT="$PWD"
preflight
SH
)"
# MUTATION PROOF: restore DRY_RUN=0 condition around check_release_toolchain in preflight.
assert_rc "real preflight rejects missing shfmt in dry run" "$?" "1"
# MUTATION PROOF: remove the missing-tool diagnostic.
assert_contains "missing tool -> preflight fails fast (#426)" "$rt_out" "Missing lint/test tool(s)"
# MUTATION PROOF: omit shfmt from LINT_TOOLCHAIN.
assert_contains "the missing tool is named (#426)" "$rt_out" "shfmt"
# MUTATION PROOF: remove the provisioning doc from the error.
assert_contains "error points at the provisioning doc (#426)" "$rt_out" "release-server.md"
for t in shellcheck shfmt node npx uv uvx; do rm -f "$RTB/$t"; done

mkdir -p "$RT_KEYS/writable"
chmod 0777 "$RT_KEYS/writable"
for element in relative "$RT_TOOLS::${RTB}" "$RT_TOOLS:" "$RT_KEYS/missing" "$RT_KEYS/writable"; do
    rt_out="$(
        rt_drive <<SH
RELEASE_TOOL_PATH='$element'
apply_release_path
SH
    )"
    # MUTATION PROOF: drop absolute/empty/existence/mode validation for this element.
    assert_rc "unsafe tool path rejected" "$?" "1"
    # MUTATION PROOF: omit the rejected element from the diagnostic (empty elements use '').
    case "$element" in *::*) rt_bad="''" ;; *:) rt_bad="''" ;; *) rt_bad="$element" ;; esac
    assert_contains "unsafe tool path is diagnosed" "$rt_out" "$rt_bad"
done
# MUTATION PROOF: split only the first tool path element, ignoring a writable second one.
rt_out="$(
    rt_drive <<'SH'
RELEASE_TOOL_PATH="$RT_EXTRA:$RT_KEYPATH/writable"
apply_release_path
SH
)"
assert_rc "every tool directory is validated" "$?" "1"

printf 'BENCH_CI_APP_ID=%s\nBENCH_CI_APP_SLUG=%s\nRELEASE_INTEGRATION_ARGS=%s\nRELEASE_TOOL_PATH=%s\n' \
    "$RT_SENTINEL" "$RT_SENTINEL" "$RT_SENTINEL" "$RT_SENTINEL" >"$RT_KEYS/env"
chmod 0600 "$RT_KEYS/env"
rt_out="$(
    rt_drive <<'SH'
# Preflight must load the file and apply its PATH before any subsequent gate.
RELEASE_TOOL_PATH="${RT_EXTRA}"
# The file must supply the App setting while the environment supplies the tool directory.
bash() { :; }
git() { printf '%s\n' "$PWD"; }
docker() { :; }
require_clean_release_tree() {
    [ "$BENCH_CI_APP_ID" = release-env-sentinel-3446 ] || exit 2
    [ "${PATH%%:*}" = "$RT_EXTRA" ] || exit 3
    /bin/sh -c 'command -v shfmt'
    exit 0
}
preflight
SH
)"
# MUTATION PROOF: remove load_release_env or apply_release_path from preflight, or move either after the clean-tree gate.
assert_rc "preflight loads settings and PATH before gates" "$?" "0"
# MUTATION PROOF: fail to export the adjusted PATH before the first gate.
assert_contains "preflight child sees tool directory" "$rt_out" "$RT_TOOLS/shfmt"
rt_out="$(
    rt_drive <<'SH'
load_release_env
for name in BENCH_CI_APP_ID BENCH_CI_APP_SLUG RELEASE_INTEGRATION_ARGS RELEASE_TOOL_PATH; do
    [ "${!name}" = release-env-sentinel-3446 ] || exit 2
done
/bin/sh -c '[ "$BENCH_CI_APP_ID" = release-env-sentinel-3446 ] &&
    [ "$BENCH_CI_APP_SLUG" = release-env-sentinel-3446 ] &&
    [ "$RELEASE_INTEGRATION_ARGS" = release-env-sentinel-3446 ] &&
    [ "$RELEASE_TOOL_PATH" = release-env-sentinel-3446 ]'
SH
)"
# MUTATION PROOF: fail to assign or export any allow-listed name.
assert_rc "env values loaded and exported" "$?" "0"
# MUTATION PROOF: log a loaded value rather than its name.
assert_not_contains "loader never logs values" "$rt_out" "$RT_SENTINEL"
for name in BENCH_CI_APP_ID BENCH_CI_APP_SLUG RELEASE_INTEGRATION_ARGS RELEASE_TOOL_PATH; do
    # MUTATION PROOF: omit per-name provenance logging.
    assert_contains "loader names each setting" "$rt_out" "loaded $name"
done
# MUTATION PROOF: omit the loaded count.
assert_contains "loader reports count" "$rt_out" "4 loaded, 0 retained"
rt_out="$(
    rt_drive <<'SH'
export BENCH_CI_APP_ID=existing BENCH_CI_APP_SLUG=''
load_release_env
[ "$BENCH_CI_APP_ID" = existing ] && [ "$BENCH_CI_APP_SLUG" = '' ]
SH
)"
# MUTATION PROOF: overwrite already-set values, including the empty string.
assert_rc "environment values win, including empty" "$?" "0"
# MUTATION PROOF: report overridden settings as loaded.
assert_contains "loader reports retained names and count" "$rt_out" "2 loaded, 2 retained"
# MUTATION PROOF: include skipped file values in the log.
assert_not_contains "retained settings do not leak file values" "$rt_out" "$RT_SENTINEL"

for name in UNKNOWN GHCR_TOKEN COSIGN_KEY COSIGN_PASSWORD RELEASE_SMOKE_CMD 'not-a-name' ''; do
    printf '# comment\n%s=%s\n' "$name" "$RT_SENTINEL" >"$RT_KEYS/env"
    rt_out="$(
        rt_drive <<'SH'
load_release_env
SH
    )"
    # MUTATION PROOF: accept this unknown/invalid name.
    assert_rc "unknown or invalid name rejected" "$?" "1"
    # MUTATION PROOF: omit the basename/line diagnostic.
    assert_contains "bad name identifies file and line" "$rt_out" "env line 2"
    # MUTATION PROOF: print the rejected line's value.
    assert_not_contains "rejected values are never logged" "$rt_out" "$RT_SENTINEL"
done
for line in "$RT_SENTINEL" 'BENCH_CI_APP_ID="unclosed' "BENCH_CI_APP_ID='"; do
    printf '# comment\n%s\n' "$line" >"$RT_KEYS/env"
    rt_out="$(
        rt_drive <<'SH'
load_release_env
SH
    )"
    # MUTATION PROOF: accept missing '=' or unmatched quotes.
    assert_rc "malformed line refused" "$?" "1"
    # MUTATION PROOF: omit the line number or echo malformed input.
    assert_contains "malformed line identified" "$rt_out" "env line 2"
    # MUTATION PROOF: echo malformed input in the diagnostic.
    assert_not_contains "malformed input value stays private" "$rt_out" "$RT_SENTINEL"
done
cat >"$RT_KEYS/env" <<'ENV'

# comment
export BENCH_CI_APP_ID="quoted value"
BENCH_CI_APP_SLUG='$HOME'
RELEASE_INTEGRATION_ARGS=--local --dir literal=path --readiness
RELEASE_TOOL_PATH=`literal`~$HOME
ENV
rt_out="$(
    rt_drive <<'SH'
load_release_env
[ "$BENCH_CI_APP_ID" = 'quoted value' ]
[ "$BENCH_CI_APP_SLUG" = '$HOME' ]
[ "$RELEASE_TOOL_PATH" = '`literal`~$HOME' ]
DRY_RUN=1
SKIP_TESTS=1
test_gate
SH
)"
# MUTATION PROOF: fail to strip matching quotes, handle export/comments, or expand values.
assert_rc "quoted values and shell syntax remain literal" "$?" "0"
# MUTATION PROOF: fail to carry loaded integration arguments to test_gate.
assert_contains "file integration args reach dry-run consumer" "$rt_out" "[dry-run] make test-integration ARGS=--local --dir literal=path --readiness"
for mode in 0666 0664 0600 0644; do
    chmod "$mode" "$RT_KEYS/env"
    rt_out="$(
        rt_drive <<'SH'
load_release_env
SH
    )"
    rt_rc=$?
    case "$mode" in 066*) rt_expected=1 ;; *) rt_expected=0 ;; esac
    # MUTATION PROOF: weaken mode & 022 or reject safe modes.
    assert_rc "env mode policy enforced" "$rt_rc" "$rt_expected"
done
ln -s "$RT_KEYS/env" "$RT_KEYS/link"
rt_out="$(
    rt_drive <<'SH'
PITHEAD_RELEASE_ENV="$RT_KEYPATH/link"
load_release_env
SH
)"
# MUTATION PROOF: remove the symlink refusal.
assert_rc "symlink env file refused" "$?" "1"
rm "$RT_KEYS/env"
rt_out="$(
    rt_drive <<'SH'
load_release_env
[ -z "${BENCH_CI_APP_ID+x}${BENCH_CI_APP_SLUG+x}${RELEASE_INTEGRATION_ARGS+x}${RELEASE_TOOL_PATH+x}" ]
SH
)"
# MUTATION PROOF: fail or set defaults when the optional env file is missing.
assert_rc "missing default env is a no-op" "$?" "0"
rt_out="$(
    rt_drive <<'SH'
PITHEAD_RELEASE_ENV="$RT_KEYPATH/missing"
load_release_env
SH
)"
# MUTATION PROOF: silently ignore a missing explicitly selected env file.
assert_rc "missing explicit env fails" "$?" "1"
rt_out="$("$RT_BASH" "$REL" --help 2>&1)"
# MUTATION PROOF: remove PITHEAD_RELEASE_ENV from the help header.
assert_contains "help names env file selector" "$rt_out" "PITHEAD_RELEASE_ENV"
# MUTATION PROOF: remove RELEASE_TOOL_PATH from the help header.
assert_contains "help names tool path" "$rt_out" "RELEASE_TOOL_PATH"
