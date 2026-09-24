#!/usr/bin/env bash
#
# Self-test for the #1002b pools leg's settle (#2407), driven as pure functions against stubs — no
# rig, no server, no docker.
#
# RigForge answers a worker-apply "accepted" and applies async (#344/#1309). The pools leg asserted
# `applied` straight off the dial and red a working rig on the bench (tier4-e2e job 563), a latent
# bug no self-test saw: selftest-rigforge-writable-keys.sh drives this leg for its gate and its
# restore source, but stubs wait_for to succeed and never counts the leg's verdicts. Here every case
# runs the REAL predicates through a one-shot wait_for, so a settle wired to `true`, or no settle at
# all, cannot pass. Its own file because that one sits at its file-budget ceiling.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/rigforge-apply-settle.sh
source "$HERE/../lib/rigforge-apply-settle.sh"
# shellcheck source=tests/integration/lib/rigforge-writable-keys.sh
source "$HERE/../lib/rigforge-writable-keys.sh"

# Ledger behavior has its own selftest.
rig_key_mark() { :; }
rig_key_clear() { :; }

# A file, not a variable: _worker_apply runs inside `$(...)`, and a variable would lose every write
# to that subshell (selftest-rigforge-writable-keys.sh explains the first run this cost).
APPLY_LOG="$(mktemp)"
trap 'rm -f "$APPLY_LOG"' EXIT
applies() { cat "$APPLY_LOG"; }

# One-shot: run the predicate once and return its verdict — no polling, no timing.
wait_for() {
    shift 3
    "$@"
}
# Change ids are minted per apply, so the revert's history row is a row of its own.
DIAL_STATUS=accepted
_worker_apply() {
    printf '%s\n' "$2" >>"$APPLY_LOG"
    printf '{"status":"%s","change_id":"c-pools-%s"}' "$DIAL_STATUS" "$(applies | grep -c .)"
}
_worker_detail() { printf '%s' "$STUB_DETAIL"; }
pools_detail() { # <rig-reported-urls-json> <probe-row-status> <revert-row-status>
    jq -cn --argjson u "$1" --arg a "$2" --arg b "$3" '{
        rig_config: {pools: [$u[] | {url: .}]}, last_applied: {},
        history: [{change_id: "c-pools-1", status: $a}, {change_id: "c-pools-2", status: $b}]}'
}

# Echoes "<passes>,<fails>" for one drive of the leg, without touching this file's own verdict.
drive() { # <rig-reported-urls-json> <probe-row-status> <revert-row-status>
    local p="$IT_PASS" f="$IT_FAIL" dp df
    STUB_DETAIL="$(pools_detail "$@")"
    : >"$APPLY_LOG"
    run_rigforge_pools rig1 >/dev/null 2>&1
    dp=$((IT_PASS - p))
    df=$((IT_FAIL - f))
    IT_PASS="$p"
    IT_FAIL="$f"
    printf '%s,%s' "$dp" "$df"
}

# Seeded (#2325: nothing on record), so the probe is also the restore target.
export IT_RIG_POOLS_PROBE='[{"url":"probe:1","pass":"secret"}]'

echo "== run_rigforge_pools: a dial-time 'accepted' is settled, never read as the verdict (#2407) =="
# The rig's reading is credential-stripped ({url} only, #113), so this pass also proves the readback
# compares URLs rather than whole values.
assert_eq "an async rig that reports the probe and settles both rows passes all four" \
    "$(drive '["probe:1"]' applied applied)" "4,0"
assert_eq "the leg wrote the probe, then restored it" "$(applies | grep -c .)" "2"

# The readback is consulted: a rig still running other pools is NOT promoted to applied, even with
# every history row already applied. Kills a settle predicate stubbed to `true`.
assert_eq "a rig that never reports the probe's URLs reds the apply and its readback" \
    "$(drive '["elsewhere:1"]' applied applied)" "1,3"

# The revert's verdict is its OWN row. Seeded, the probe and the restore are one value, so the
# readback matches before the revert has done anything; only c-pools-2 can say it landed. Kills
# dropping the revert's history settle.
assert_eq "a revert whose own history row never settles reds the revert, and only it" \
    "$(drive '["probe:1"]' applied accepted)" "3,1"

# The probe's own row is asserted too: the readback is as blind for the probe once the seed is on
# the rig, so an unreconciled row must red rather than ride the readback's pass.
assert_eq "a probe whose history row never settles reds that row" \
    "$(drive '["probe:1"]' accepted applied)" "3,1"

# A refusal is left alone by the settle: the readback may match, the verdict must not change.
DIAL_STATUS=rejected
assert_eq "a dial-time 'rejected' is never promoted to applied, readback or not" \
    "$(drive '["probe:1"]' rejected rejected)" "0,4"
DIAL_STATUS=accepted

echo ""
echo "selftest-rigforge-pools-settle: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
