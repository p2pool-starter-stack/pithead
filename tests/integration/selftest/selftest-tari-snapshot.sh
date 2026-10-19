#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals are consumed by sourced helpers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/tari_snapshot_test.py"
source "$HERE/../lib/tari-snapshot.sh"
source "$HERE/../lib/harness-args.sh"
die() {
    echo "$*" >&2
    exit 1
}
MODE=targeted KEEP=0
CI_JOB_ID=7 CI_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CI_TARI_SNAPSHOT_RESTORE_STATE=receipt IT_SCRATCH_DIR=scratch
HARNESS_ARGS=(--tari-data snapshot)
validate_harness_args
validate_tari_data
[ "$TARI_DATA" = snapshot ] && [ -z "$HARNESS_PHASE_ARGS" ] && [ -z "$HARNESS_SCENARIO_ARGS" ]
HARNESS_ARGS=(--tari-data snapshot --auth-fail-closed)
TARI_DATA=""
validate_harness_args
[ "$HARNESS_PHASE_ARGS" = ' --auth-fail-closed' ]
for value in snapshot-lagged invalid ''; do
    if (
        TARI_DATA="$value"
        [ -n "$value" ] || exit 1
        validate_tari_data
    ) >/dev/null 2>&1; then exit 1; fi
done
if (
    KEEP=1
    validate_tari_data
) >/dev/null 2>&1; then exit 1; fi
if (
    MODE=check
    validate_tari_data
) >/dev/null 2>&1; then exit 1; fi
printf 'Tari snapshot parsing and receipt selftest: PASS\n'
