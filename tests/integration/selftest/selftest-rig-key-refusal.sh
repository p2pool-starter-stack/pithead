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
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-rig-control.sh
source "$HERE/../lib/run-rig-control.sh" # _max_temp_round_trip (the stub below replaces its _worker_apply)
# shellcheck source=tests/integration/lib/run-rig-reverse.sh
source "$HERE/../lib/run-rig-reverse.sh" # run_rigforge_reverse

# The refusal under test: the ledger could not record the original.
rig_key_mark() { return 1; }
rig_key_clear() { :; }

# A FILE, not a variable: the code under test calls _worker_apply inside `$(...)`, whose subshell
# would swallow a variable's writes (see selftest-rigforge-writable-keys.sh).
APPLY_LOG="$(mktemp)"
_worker_apply() {
    printf '%s\n' "$2" >>"$APPLY_LOG"
    printf '{"status":"accepted","change_id":"c-x"}'
}
# The #516 leg dials the rig directly, not through the dashboard, so it has its own log.
RIG_LOG="$(mktemp)"
trap 'rm -f "$APPLY_LOG" "$RIG_LOG"' EXIT
_rig_control_apply() { printf '%s\n' "$1" >>"$RIG_LOG"; }
env_on_box() { :; } # no CONTROL_DIR: the reverse leg's prefill half skips itself
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

# #513: max_temp_c through the dashboard.
: >"$APPLY_LOG"
_max_temp_round_trip rig1 100 >/dev/null 2>&1
assert_eq "the max_temp_c leg POSTs nothing (_worker_apply never called)" "$(grep -c . "$APPLY_LOG")" "0"

# #516: max_temp_c straight at the rig's control API.
: >"$RIG_LOG"
IT_RIG_TOKEN=tok RIG_HOST=rig1.invalid RIG_CONTROL_PORT=8082 run_rigforge_reverse rig1 100 >/dev/null 2>&1
assert_eq "the #516 leg dials nothing (_rig_control_apply never called)" "$(grep -c . "$RIG_LOG")" "0"

echo ""
echo "selftest-rig-key-refusal: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
