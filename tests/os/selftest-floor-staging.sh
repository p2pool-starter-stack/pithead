#!/usr/bin/env bash
# Regression for #3049: the floor-fallback leg separates bundle staging from os-update. A failed
# staging must report an environment/transport fault with its scp stderr and never invoke
# os-update; a successful staging must still run os-update.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SERIAL="$T/serial" KEY="$T/key" ip=192.0.2.1 VM=selftest PASS=0 FAIL=0 KEEP=1 OS_RUN_SUITE=1
# shellcheck source=tests/os/lib/core.sh
source "$HERE/lib/core.sh"
# shellcheck source=tests/os/staging-failure-evidence.sh
source "$HERE/staging-failure-evidence.sh"
# shellcheck source=tests/os/data-floor-fallback-leg.sh
SCRIPT_DIR="$HERE" source "$HERE/data-floor-fallback-leg.sh"
trap 'rm -rf "$T"' EXIT
SERIAL="$T/serial" STAGE_ERR="$T/stage-error"
printf 'console line\n' >"$SERIAL"
printf 'bundle' >"$T/bundle"

OSUPDATE_CALLS=0
_ssh() {
    case "$*" in *os-update*) OSUPDATE_CALLS=$((OSUPDATE_CALLS + 1)) ;; esac
    echo "probe-output"
}
mkdir "$T/bin"
printf '#!/bin/sh\necho running\n' >"$T/bin/virsh"
chmod +x "$T/bin/virsh"
PATH="$T/bin:$PATH"
fail() { echo "FAIL: $1"; exit 1; }

# The staging bound is real: a hung scp is killed at STAGE_TIMEOUT with rc 124.
printf '#!/bin/sh\nsleep 30\n' >"$T/bin/scp"
chmod +x "$T/bin/scp"
# shellcheck disable=SC2218 # the real one from core.sh; the stub below replaces it afterwards
STAGE_TIMEOUT=1 _stage_bundle "$T/bundle"
rc=$?
[ "$rc" -eq 124 ] || fail "hung scp not bounded (rc $rc)"

# Failed staging: scp stderr and rc retained, os-update never invoked.
_stage_bundle() {
    echo 'scp: Connection closed' >"$STAGE_ERR"
    return 255
}
out=$(_floor_stage "$T/bundle")
rc=$?
[ "$rc" -ne 0 ] || fail "failed staging returned success"
[ "$OSUPDATE_CALLS" -eq 0 ] || fail "os-update invoked on failed staging"
for want in 'rc=255' 'environment/transport fault' 'os-update was NOT invoked' 'scp: Connection closed' 'domain state: running' 'console line' 'probe-output'; do
    printf '%s' "$out" | grep -qF -- "$want" || fail "evidence lacks: $want"
done
[ -f "$SERIAL.failed" ] || fail "serial not retained"

# Successful staging still reaches os-update.
_stage_bundle() { return 0; }
_floor_stage "$T/bundle" || fail "successful staging reported failure"
_floor_os_update >/dev/null
[ "$OSUPDATE_CALLS" -eq 1 ] || fail "os-update not invoked after good staging"
printf 'selftest-floor-staging: ok\n'
