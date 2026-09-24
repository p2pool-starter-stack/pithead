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
# all, cannot pass. The same drives decide the #1379 restore ledger, so its retire rule is pinned
# here too: an entry kept or retired on the wrong verdict passes every assertion on the leg's rows.
# Its own file because that one sits at its file-budget ceiling.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/rigforge-apply-settle.sh
source "$HERE/../lib/rigforge-apply-settle.sh"
# shellcheck source=tests/integration/lib/rigforge-writable-keys.sh
source "$HERE/../lib/rigforge-writable-keys.sh"

# Files, not variables: _worker_apply runs inside `$(...)`, and a variable would lose every write
# to that subshell (selftest-rigforge-writable-keys.sh explains the first run this cost).
APPLY_LOG="$(mktemp)"
MARK_LOG="$(mktemp)" # the #1379 ledger calls the leg makes; the ledger itself has its own selftest
trap 'rm -f "$APPLY_LOG" "$MARK_LOG"' EXIT
applies() { cat "$APPLY_LOG"; }
rig_key_mark() { echo mark >>"$MARK_LOG"; }
rig_key_clear() { echo clear >>"$MARK_LOG"; }
ledger() { paste -sd, "$MARK_LOG"; } # "mark" = kept for the EXIT unwind, "mark,clear" = retired

# One-shot: run the predicate once and return its verdict — no polling, no timing.
wait_for() {
    shift 3
    "$@"
}
DIAL_STATUS=accepted
_worker_apply() {
    printf '%s\n' "$2" >>"$APPLY_LOG"
    [ -z "$DIAL_STATUS" ] || printf '{"status":"%s","change_id":"c-pools"}' "$DIAL_STATUS"
}
_worker_detail() { printf '%s' "$STUB_DETAIL"; }
pools_detail() { # <rig-reported-urls-json> <history-row-status>
    jq -cn --argjson u "$1" --arg a "$2" '{
        rig_config: {pools: [$u[] | {url: .}]}, last_applied: {},
        history: [{change_id: "c-pools", status: $a}]}'
}

# Echoes "<passes>,<fails>" for one drive of the leg, without touching this file's own verdict.
drive() { # <rig-reported-urls-json> <history-row-status>
    local p="$IT_PASS" f="$IT_FAIL" dp df
    STUB_DETAIL="$(pools_detail "$@")"
    : >"$APPLY_LOG"
    : >"$MARK_LOG"
    run_rigforge_pools rig1 >/dev/null 2>&1
    dp=$((IT_PASS - p))
    df=$((IT_FAIL - f))
    IT_PASS="$p"
    IT_FAIL="$f"
    printf '%s,%s' "$dp" "$df"
}

export IT_RIG_POOLS_PROBE='[{"url":"probe:1","pass":"secret"}]'

echo "== run_rigforge_pools: a dial-time 'accepted' is settled, never read as the verdict (#2407) =="
# The rig's reading is credential-stripped ({url} only, #113), so this pass also proves the readback
# compares URLs rather than whole values.
assert_eq "an async rig that reports the probe and settles its row passes all three" \
    "$(drive '["probe:1"]' applied)" "3,0"
assert_eq "the leg wrote the probe once (#2470: the probe is its own restore)" "$(applies | grep -c .)" "1"

# The readback is consulted: a rig still running other pools is NOT promoted to applied, even with
# its history row already applied. Kills a settle predicate stubbed to `true`.
assert_eq "a rig that never reports the probe's URLs reds the apply and its readback" \
    "$(drive '["elsewhere:1"]' applied)" "1,2"

# The row is asserted too: once a run has left the rig on the probe the readback matches before this
# apply has done anything, so an unreconciled row must red rather than ride the readback's pass.
assert_eq "a change whose history row never settles reds that row" \
    "$(drive '["probe:1"]' accepted)" "2,1"

# A refusal is left alone by the settle: the readback may match, the verdict must not change.
DIAL_STATUS=rejected
assert_eq "a dial-time 'rejected' is never promoted to applied, readback or not" \
    "$(drive '["probe:1"]' rejected)" "0,3"
DIAL_STATUS=accepted

echo "== run_rigforge_pools: the #1379 ledger retires on what the rig decided, and only on that =="
# The realistic path: the dial says "accepted", so the verdict arrives on the readback and the row.
# A readback that never matches leaves the settle at "accepted", which is how a timeout looks here.
# <rig-reported-urls> <row> <ledger>: `applied` needs both halves; a refusal on the row is final.
for _case in '["probe:1"] applied mark,clear' '["elsewhere:1"] applied mark' \
    '["elsewhere:1"] accepted mark' '["probe:1"] accepted mark' '["probe:1"] failed mark' \
    '["elsewhere:1"] rejected mark,clear' '["elsewhere:1"] rolled_back mark,clear'; do
    read -r _urls _row _want <<<"$_case"
    drive "$_urls" "$_row" >/dev/null
    assert_eq "dial accepted, rig reports $_urls, row $_row: ledger [$_want]" "$(ledger)" "$_want"
done
DIAL_STATUS=rejected
drive '["elsewhere:1"]' accepted >/dev/null
assert_eq "a dial-time 'rejected' retires the entry before any row is written" "$(ledger)" "mark,clear"
DIAL_STATUS="" # no answer at all: the rig may or may not have taken the probe
drive '["probe:1"]' applied >/dev/null
assert_eq "a dial with no answer keeps the entry for the unwind" "$(ledger)" "mark"
DIAL_STATUS=accepted

echo ""
echo "selftest-rigforge-pools-settle: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
