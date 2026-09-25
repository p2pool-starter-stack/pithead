#!/usr/bin/env bash
#
# Self-test (#2455): deploy_branch's post-recreate settle must actually outlast a recreated
# tari's real reconnect time, or the one-shot readiness check right after it (which never
# retries) fails on a tari that is merely still reconnecting, not unsynced. Standalone (not
# folded into selftest-e2e-phases.sh) so it never pushes that file past its
# docs/dev/file-budget.tsv ceiling — same reasoning as selftest-harness-pregate.sh.
#
# The defect: deploy_branch waited only 300s (5min) before the harness's binding readiness
# gate ran, but #2455 measured a recreated tari reconnecting over Tor at >18min — the wait
# gave up long before tari settled, and the readiness check then failed on a healthy stack.
# No server, no bench, no rig. Run directly, or via `make test-integration-selftest`.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

E2E_SRC="$HERE/../e2e.sh"

# --- Extract the real functions from the shipped e2e.sh, never a re-spelling ----------------
# Fail CLOSED: if a refactor moves or renames either function this must go red, same reasoning
# as selftest-e2e-phases.sh's run_harness extraction.
WAIT_SRC="$(sed -n '/^wait_synced() {/,/^}$/p' "$E2E_SRC")"
assert_eq "wait_synced extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$WAIT_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "wait_synced() { # <timeout_s> } "

DEPLOY_SRC="$(sed -n '/^deploy_branch() {$/,/^}$/p' "$E2E_SRC")"
assert_eq "deploy_branch extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$DEPLOY_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "deploy_branch() { } "

echo "== deploy_branch's own settle ceiling covers the measured real reconnect time (#2455) =="
assert_eq "deploy_branch calls wait_synced exactly once" \
    "$(printf '%s\n' "$DEPLOY_SRC" | grep -c 'wait_synced [0-9]')" "1"
WAIT_ARG="$(printf '%s\n' "$DEPLOY_SRC" | grep -oE 'wait_synced [0-9]+' | grep -oE '[0-9]+')"
if [ "${WAIT_ARG:-0}" -ge 1080 ] 2>/dev/null; then
    it_pass "deploy_branch's wait_synced ceiling (${WAIT_ARG}s) is >= 1080s (18min, #2455's measurement)"
else
    it_fail "deploy_branch's wait_synced ceiling is >= 1080s (18min, #2455's measurement)" "got ${WAIT_ARG:-<none>}s"
fi
assert_contains "deploy_branch refuses destructive phases when the bounded settle expires" "$DEPLOY_SRC" \
    'wait_synced 1500 || die "post-deploy chain readiness did not recover within 1500s; destructive phases refused."'

# --- Drive the real wait_synced with SSH/sleep stubbed out ----------------------------------
run_wait_synced() { # <timeout_s> <first-state> [state-after-one-poll] -> "<rc>"
    # shellcheck disable=SC2034,SC2329  # STATE is read by on_bench; eval'd below, shellcheck cannot follow into it
    (
        STATE="$2"
        NEXT="${3:-}"
        ok() { :; }
        warn() { :; }
        sleep() { [ -z "$NEXT" ] || STATE="$NEXT"; } # no real waiting
        on_bench() { printf '%s' "$STATE"; }
        eval "$WAIT_SRC"
        wait_synced "$1"
        echo "rc=$?"
    ) 2>/dev/null | sed -n 's/^rc=//p'
}

echo "== wait_synced honors the timeout it's given (generic, not #2455-specific) =="
assert_eq "an already-synced bench returns 0 immediately" "$(run_wait_synced 5 done/done)" "0"
assert_eq "a delayed Tari reconnect proceeds once the existing done/done predicate passes" \
    "$(run_wait_synced 5 loading/loading done/done)" "0"
assert_eq "a bench stuck loading returns 1 once its OWN timeout elapses" "$(run_wait_synced 1 loading/loading)" "1"

# --- The other caller that runs the SAME `pithead upgrade` with the SAME short-wait defect ---
# run-matrix.sh/run-rigforge.sh also call wait_tari_synced 300, but their wait feeds into
# assert_tari_synced_required (#746), which already tolerates post-restart lag once Tari has
# proved synced this run — they are not exposed to #2455's bug. live-gates.sh's run_image_upgrade
# hard-fails straight off wait_tari_synced with no such tolerance, on the exact `pithead upgrade`
# #2455 names, so it needs the same ceiling raise.
LIVE_GATES_SRC="$HERE/../lib/live-gates.sh"
UPGRADE_SRC="$(sed -n '/^run_image_upgrade() {$/,/^}$/p' "$LIVE_GATES_SRC")"
assert_eq "run_image_upgrade extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$UPGRADE_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "run_image_upgrade() { } "
UPGRADE_WAIT_ARG="$(printf '%s\n' "$UPGRADE_SRC" | grep -oE 'wait_tari_synced [0-9]+' | grep -oE '[0-9]+')"
if [ "${UPGRADE_WAIT_ARG:-0}" -ge 1080 ] 2>/dev/null; then
    it_pass "run_image_upgrade's wait_tari_synced ceiling (${UPGRADE_WAIT_ARG}s) is >= 1080s (18min, #2455's measurement)"
else
    it_fail "run_image_upgrade's wait_tari_synced ceiling is >= 1080s (18min, #2455's measurement)" "got ${UPGRADE_WAIT_ARG:-<none>}s"
fi

printf '\npassed: %s, failed: %s\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
