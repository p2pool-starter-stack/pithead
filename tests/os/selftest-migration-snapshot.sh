#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/tmp}}"
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
(
    S="$T/leak"
    mkdir -p "$S/fakebin/src/os/rauc" "$S/tmp"
    printf '#!/bin/sh\nexit 0\n' >"$S/fakebin/src/os/build-image.sh"
    printf '#!/bin/sh\nmkdir -p os/rauc/build && printf bundle >os/rauc/build/update.raucb\n' >"$S/fakebin/src/os/rauc/mkbundle.sh"
    chmod +x "$S/fakebin/src/os/build-image.sh" "$S/fakebin/src/os/rauc/mkbundle.sh"
    printf '#!/bin/sh\n[ "$1" = archive ] && exec tar -c -C "%s" os\nexit 1\n' "$S/fakebin/src" >"$S/fakebin/git"
    chmod +x "$S/fakebin/git"
    export PATH="$S/fakebin:$PATH" TMPDIR="$S/tmp" OS_RUN_SUITE=1 SCRIPT_DIR="$HERE"
    SERIAL="$S/serial" PASS=0 FAIL=0 KEEP=1 VM=selftest DISK="$S/disk" SSH_ERR="$S/ssh-err" KEY="$S/key"
    printf 'pub\n' >"$KEY.pub"
    # shellcheck source=tests/os/lib/core.sh
    source "$HERE/lib/core.sh"
    # shellcheck source=tests/os/data-floor-fallback-leg.sh
    source "$HERE/data-floor-fallback-leg.sh"
    package_appliance_cleanup() { :; }
    approval_fixture_cleanup() { :; }
    resolve_signing_material() { RAUC_CERT="$S/cert" RAUC_KEY="$S/key" RAUC_KEYRING="$S/keyring"; }
    printf 'good bundle\n' >"$S/update.raucb"
    saved=$(preserve_migration_bundle "$S/update.raucb")
    stamped=$(_build_bundle_stamped vfail 99.0.0 99.0.0)
    for f in "$saved" "$stamped"; do
        [ -f "$f" ] || {
            echo "FAIL: $f was not created"
            exit 1
        }
        [[ "$f" == "$HOST_SCRATCH/"* ]] || {
            echo "FAIL: $f is outside the owned scratch directory"
            exit 1
        }
    done
    cleanup
    [ -z "$(find "$S/tmp" -name 'pithead-migration-*' -o -name 'os-floor-fallback-*')" ] &&
        [ ! -e "$HOST_SCRATCH" ] || {
        echo 'FAIL: cleanup left saved RAUC bundles behind'
        exit 1
    }
)
echo 'selftest-migration-bundle-preservation: PASS'
