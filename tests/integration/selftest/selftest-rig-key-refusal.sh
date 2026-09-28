#!/usr/bin/env bash
#
# Self-test for #2668's caller half: when rig_key_mark refuses a value (it is not one JSON value, so
# an abort could not restore it), the writable-key legs must NOT send the write. A write with no
# ledger entry is one the abort-safe unwind cannot undo. Driven as pure functions against stubs —
# no rig, no server, no docker. The ledger's own behaviour is selftest-rig-key-ledger.sh.
#
# Standalone, like selftest-rigforge-writable-keys.sh, which stays under its file-budget ceiling.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/rigforge-apply-settle.sh
source "$HERE/../lib/rigforge-apply-settle.sh"
# shellcheck source=tests/integration/lib/rigforge-writable-keys.sh
source "$HERE/../lib/rigforge-writable-keys.sh"

# The refusal under test: the ledger could not record the original.
rig_key_mark() { return 1; }
rig_key_clear() { :; }

# A FILE, not a variable: the code under test calls _worker_apply inside `$(...)`, whose subshell
# would swallow a variable's writes (see selftest-rigforge-writable-keys.sh).
APPLY_LOG="$(mktemp)"
trap 'rm -f "$APPLY_LOG"' EXIT
_worker_apply() {
    printf '%s\n' "$2" >>"$APPLY_LOG"
    printf '{"status":"accepted","change_id":"c-x"}'
}
_worker_detail() { printf '%s' "$STUB_DETAIL"; }
wait_for() { return 0; }

echo "== a refused ledger mark sends NO write (#2668) =="
STUB_DETAIL='{"rig_config":{"DONATION":0}}'
: >"$APPLY_LOG"
before=$((IT_PASS + IT_FAIL))
_writable_key_round_trip rig1 DONATION 0 1 >/dev/null 2>&1
assert_eq "the writable-key round trip POSTs nothing" "$(grep -c . "$APPLY_LOG")" "0"
assert_eq "and asserts nothing (a skip, not a red)" "$((IT_PASS + IT_FAIL - before - 1))" "0"

STUB_DETAIL='{"last_applied":{"pools":[{"url":"real:1","pass":"secret"}]}}'
IT_RIG_POOLS_PROBE='[{"url":"probe:1","pass":"probesecret"}]'
: >"$APPLY_LOG"
run_rigforge_pools rig1 >/dev/null 2>&1
assert_eq "the pools leg POSTs nothing" "$(grep -c . "$APPLY_LOG")" "0"

echo ""
echo "selftest-rig-key-refusal: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
