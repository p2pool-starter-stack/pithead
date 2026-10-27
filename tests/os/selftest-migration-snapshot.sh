#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?set TMPDIR or RUNNER_TEMP}}"
HERE=$(cd "$(dirname "$0")" && pwd)
python3 "$HERE/selftest-migration-snapshot.py"

# A later same-version health-fault build must not overwrite the good recovery input.
# shellcheck source=tests/os/migration-same-version-fallback.sh
source "$HERE/migration-same-version-fallback.sh"
T=$(mktemp -d "${TMPDIR:?}/migration-bundles.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir "$T/scratch"
for temporary_dir in configured unset empty; do
    (
        unset RUNNER_TEMP
        case "$temporary_dir" in
        configured)
            export TMPDIR="$T/scratch"
            expected="$T/scratch"
            ;;
        unset)
            unset TMPDIR
            expected="$T"
            ;;
        empty)
            export TMPDIR=''
            expected="$T"
            ;;
        esac
        printf 'good bundle\n' >"$T/update.raucb"
        saved=$(preserve_migration_bundle "$T/update.raucb")
        [[ "$saved" == "$expected/pithead-migration-good."* ]] || {
            echo 'FAIL: preserved bundle escaped its owned scratch directory'
            exit 1
        }
        # The real builder removes/recreates update.raucb, then discovers *.raucb.
        rm "$T/update.raucb"
        printf 'fault bundle\n' >"$T/update.raucb"
        [ "$(find "$T" -name '*.raucb')" = "$T/update.raucb" ] || {
            echo 'FAIL: fault builder can discover the preserved good bundle'
            exit 1
        }
        [ "$(cat "$saved")" = 'good bundle' ] || {
            echo 'FAIL: fault build destroyed the good bundle'
            exit 1
        }
        rm "$saved"
    )
done
echo 'selftest-migration-bundle-preservation: PASS'
