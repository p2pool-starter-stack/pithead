#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?set TMPDIR or RUNNER_TEMP}}"
HERE=$(cd "$(dirname "$0")" && pwd)
python3 "$HERE/selftest-migration-snapshot.py"

# A later same-version health-fault build must not overwrite the good recovery input.
# shellcheck source=tests/os/migration-same-version-fallback.sh
source "$HERE/migration-same-version-fallback.sh"
T=$(mktemp -d "${TMPDIR:?}/migration-bundles.XXXXXX")
trap 'rm -rf "$T"; [ -z "${saved:-}" ] || rm -f "$saved"' EXIT
printf 'good bundle\n' >"$T/update.raucb"
saved=$(preserve_migration_bundle "$T/update.raucb")
printf 'fault bundle\n' >"$T/update.raucb"
[ "$(cat "$saved")" = 'good bundle' ] || {
    echo 'FAIL: fault build destroyed the good bundle'
    exit 1
}
echo 'selftest-migration-bundle-preservation: PASS'
