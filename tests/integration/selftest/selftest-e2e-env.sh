#!/usr/bin/env bash
#
# Self-test (#2643, bench-ci#613): every place the harness stops because of the bench prints the
# one line bench-ci's tier4-e2e reads, `e2e-env: <key>`, alone on stdout and at most once, and no
# other path prints it. bench-ci used to grep this harness's prose instead, and a reworded warning
# turned a bench abort into a branch failure; the post-deploy Tari wait had already drifted.
#
# Each case drives the function a live run calls (assert_mining_state, wait_synced, the readiness
# phase, wait_tari_synced + assert_tari_synced_required, harness_pregate, preflight, run_harness)
# with only SSH, sleep and the dashboard stubbed, and asserts every line that mentions e2e-env:
# in its output. No server, no bench, no rig. Run directly, or via `make test-integration-selftest`.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/detached-harness.sh
source "$HERE/../lib/detached-harness.sh"
# shellcheck source=tests/integration/lib/remote-endpoints.sh
source "$HERE/../lib/remote-endpoints.sh"
# shellcheck disable=SC2034  # read by the run module sourced next
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-scenario.sh
source "$HERE/../lib/run-scenario.sh"

E2E_SRC="$HERE/../e2e.sh"

said() { grep -a 'e2e-env:' || true; } # every line that mentions the prefix, well-formed or not

# --- Extract the real e2e.sh functions, never a re-spelling --------------------------------
# Fail CLOSED: an extraction that stops matching must go red, not quietly test nothing.
extract() { # <name> -> the function's source
    sed -n "/^$1() {/,/^}\$/p" "$E2E_SRC"
}
WAIT_SRC="$(extract wait_synced)"
PREFLIGHT_SRC="$(extract preflight)"
HARNESS_SRC="$(extract run_harness)"
for f in wait_synced preflight run_harness; do
    src="$(extract "$f")"
    assert_eq "$f extraction is the whole function (opens and closes)" \
        "$(printf '%s\n' "$src" | sed -n '1{s/ *#.*//;p};$p' | tr '\n' ' ')" "$f() { } "
done

echo "== the printer: one fixed line, one key per process, nothing for an unknown key =="
assert_eq "e2e_env prints the bare line" "$(e2e_env readiness)" "e2e-env: readiness"
assert_eq "a second call in the same process prints nothing" \
    "$( (e2e_env chains-behind && e2e_env tari-not-done && e2e_env chains-behind) | said)" "e2e-env: chains-behind"
(e2e_env disk-full) >/dev/null
assert_rc "an unknown key is refused" "$?" "1"
assert_eq "an unknown key prints nothing" "$( (e2e_env disk-full) | said)" ""

echo "== workers-offline: a --check run with no worker online (assert_mining_state) =="
mining_of() { # <check_only> <skip> <workers> <expected> [calls] -> the lines assert_mining_state printed
    (
        CHECK_ONLY="$1"
        for _ in $(seq 1 "${5:-1}"); do assert_mining_state "$2" "$3" 0 "$4"; done
    ) 2>/dev/null | said
}
assert_eq "--check with 0 of 1 workers online says workers-offline" "$(mining_of 1 0 0 1)" "e2e-env: workers-offline"
assert_eq "an unreported worker count reads as 0, as the assertion reads it" "$(mining_of 1 0 "" 1)" "e2e-env: workers-offline"
assert_eq "asserted again in the same run, it is still one line" "$(mining_of 1 0 0 1 3)" "e2e-env: workers-offline"
assert_eq "one worker online (short of 2) is not offline" "$(mining_of 1 0 1 2)" ""
assert_eq "a matrix scenario's 0 workers is the branch's: nothing" "$(mining_of 0 0 0 1)" ""
assert_eq "--no-mining-asserts skips the leg: nothing" "$(mining_of 1 1 0 1)" ""
assert_eq "0 expected workers never fails the leg: nothing" "$(mining_of 1 0 0 0)" ""

echo "== tari-not-done: deploy_branch's post-deploy wait gives up on Tari (wait_synced) =="
synced_of() { # <state> -> the lines wait_synced printed, then its rc
    # shellcheck disable=SC2329  # the stubs are called by the eval'd wait_synced
    (
        STATE="$1"
        ok() { :; }
        warn() { :; }
        sleep() { :; }
        on_bench() { printf '%s' "$STATE"; }
        eval "$WAIT_SRC"
        wait_synced 0
        echo "rc=$?"
    ) 2>/dev/null | grep -a -e 'e2e-env:' -e '^rc='
}
assert_eq "Tari still syncing after the wait says tari-not-done" "$(synced_of done/syncing)" $'e2e-env: tari-not-done\nrc=1'
assert_eq "Tari still loading after the wait says tari-not-done" "$(synced_of done/loading)" $'e2e-env: tari-not-done\nrc=1'
assert_eq "both chains behind: Tari is still not done" "$(synced_of loading/syncing)" $'e2e-env: tari-not-done\nrc=1'
assert_eq "Monero behind, Tari done: not a Tari abort" "$(synced_of loading/done)" "rc=1"
assert_eq "a dashboard that never answered is the branch's" "$(synced_of "")" "rc=1"
assert_eq "a dashboard without the panels is the branch's" "$(synced_of null/null)" "rc=1"
assert_eq "both done: no line, the wait passes" "$(synced_of done/done)" "rc=0"
assert_contains "deploy_branch stops the run when that wait gives up" "$(extract deploy_branch)" \
    'wait_synced 1500 || die "post-deploy chain readiness did not recover within 1500s; destructive phases refused."'

echo "== tari-not-done: the readiness phase's Tari is synced refusal (assert_release_readiness) =="
readiness_of() { # <tari state> -> the lines the readiness phase printed
    # shellcheck disable=SC2034,SC2329  # the stubs and inputs are read by assert_release_readiness
    (
        TARI_STATE="$1" FULL_DATA_DIR="" PRUNED_DATA_DIR="" BASELINE_PRUNE=1
        monero_caught_up() { return 0; }
        pithead() { return 0; }
        env_on_box() { :; }
        rx() { case "$1" in *api/state*) printf '{"sync":{"tari":{"state":"%s"}}}' "$TARI_STATE" ;; *) return 1 ;; esac }
        assert_release_readiness
    ) 2>/dev/null | said
}
assert_eq "readiness refusing on a syncing Tari says tari-not-done" "$(readiness_of syncing)" "e2e-env: tari-not-done"
assert_eq "readiness refusing on a loading Tari says tari-not-done" "$(readiness_of loading)" "e2e-env: tari-not-done"
assert_eq "a dashboard that did not answer names no Tari (harness_pregate says readiness)" "$(readiness_of "")" ""
assert_eq "a Tari that is done says nothing (the phase's other refusals are harness_pregate's)" \
    "$(readiness_of "done")" ""

echo "== tari-sync-timeout: local-pruned-main-secure-tari's Tari wait timed out (lib.sh) =="
tari_timeout_of() { # <scenario> <wait: timeout|ok> <state> [seen_done] -> the lines printed
    # shellcheck disable=SC2034,SC2329  # the stubs and inputs are read by the lib.sh helpers
    (
        IT_CURRENT_SCENARIO="$1" TARI_SEEN_DONE="${4:-0}"
        sleep() { :; }
        if [ "$2" = timeout ]; then _pred_tari_synced() { return 1; }; else _pred_tari_synced() { return 0; }; fi
        wait_tari_synced 0
        assert_tari_synced_required "$3"
    ) 2>/dev/null | said
}
assert_eq "the wait timed out and Tari is not done, in local-pruned-main-secure-tari" \
    "$(tari_timeout_of local-pruned-main-secure-tari timeout syncing)" "e2e-env: tari-sync-timeout"
assert_eq "the same failure in any other scenario says nothing" \
    "$(tari_timeout_of remote-main-secure-tari timeout syncing)" ""
assert_eq "a failure without a timed-out wait says nothing" \
    "$(tari_timeout_of local-pruned-main-secure-tari ok syncing)" ""
assert_eq "a dashboard that stopped answering is the branch's: nothing" \
    "$(tari_timeout_of local-pruned-main-secure-tari timeout "")" ""
assert_eq "an in-progress Tari after it proved done is a warning, not a failure: nothing" \
    "$(tari_timeout_of local-pruned-main-secure-tari timeout loading 1)" ""
wait_rc() { # <wait: timeout|ok> -> wait_tari_synced's rc, which live-gates.sh's image-upgrade reads
    # shellcheck disable=SC2329
    (
        sleep() { :; }
        if [ "$1" = timeout ]; then _pred_tari_synced() { return 1; }; else _pred_tari_synced() { return 0; }; fi
        wait_tari_synced 0
    ) >/dev/null 2>&1
}
wait_rc timeout
assert_rc "wait_tari_synced still fails when it times out" "$?" "1"
wait_rc ok
assert_rc "wait_tari_synced still passes when Tari is synced" "$?" "0"

echo "== readiness: harness_pregate's readiness phase refused (never its check phase) =="
pregate_of() { # <failing phase|none> [readiness names Tari: 1] [check says workers-offline: 1] -> lines, rc
    # shellcheck disable=SC2034,SC2329  # the stubs and inputs are read by harness_pregate
    (
        E2E_DIR=/srv/code/pithead-e2e FAIL="$1" TARI="${2:-0}" WORKERS_LINE="${3:-0}"
        warn() { :; }
        on_bench() {
            case "$1" in
            *--readiness*)
                [ "$TARI" != 1 ] || printf '    ✗ Tari is synced\ne2e-env: tari-not-done\n'
                [ "$FAIL" != readiness ]
                ;;
            *--check*)
                [ "$WORKERS_LINE" != 1 ] || printf 'e2e-env: workers-offline\n'
                [ "$FAIL" != check ]
                ;;
            esac
        }
        harness_pregate 1 ""
        echo "rc=$?"
    ) </dev/null 2>/dev/null | grep -a -e 'e2e-env:' -e '^rc='
}
assert_eq "a readiness refusal (a busy rig lock, a lost SSH, a failed leg) says readiness" \
    "$(pregate_of readiness)" $'e2e-env: readiness\nrc=1'
assert_eq "a readiness refusal on Tari is tari-not-done alone, so bench-ci's Tari retry applies" \
    "$(pregate_of readiness 1)" $'e2e-env: tari-not-done\nrc=1'
assert_eq "a check refusal adds nothing: that phase reads the deployed branch" \
    "$(pregate_of check)" "rc=1"
assert_eq "a check refusal that said workers-offline itself keeps that one line" \
    "$(pregate_of check 0 1)" $'e2e-env: workers-offline\nrc=1'
assert_eq "a pregate that passes says nothing" "$(pregate_of none)" "rc=0"

echo "== chains-behind: the #914 preflight finds the bench chains off tip (preflight) =="
preflight_of() { # <sync summary> [skip_preflight] -> the lines preflight printed, then rc
    # shellcheck disable=SC2034,SC2329  # the stubs and inputs are read by the eval'd preflight
    (
        SYNC="$1" SKIP_PREFLIGHT="${2:-0}" MODE=check BORROW_MINER=0 BENCH_HOST=bench MINER_HOST=""
        CANONICAL_DIR=/srv/code/pithead E2E_DIR=/srv/code/pithead-e2e RESTORE_DIR=/srv/code/pithead
        E2E_SYNC_SUMMARY_JQ=. C_RED="" C_RESET=""
        log() { :; }
        ok() { :; }
        warn() { :; }
        parent_lock_checkpoint() { :; }
        stack_image_census() { :; }
        on_bench() { case "$1" in *api/state*) printf '%s' "$SYNC" ;; esac }
        eval "$(sed -n '/^die() {/,/^}$/p' "$E2E_SRC")"
        eval "$PREFLIGHT_SRC"
        preflight
        echo "rc=$?"
    ) </dev/null 2>/dev/null | grep -a -e 'e2e-env:' -e '^rc='
}
assert_eq "Tari off tip at preflight says chains-behind and stops" \
    "$(preflight_of 'done 3300000/3300000 syncing 81000/81200')" "e2e-env: chains-behind"
assert_eq "Monero off tip at preflight says chains-behind and stops" \
    "$(preflight_of 'syncing 3200000/3300000 done 81200/81200')" "e2e-env: chains-behind"
assert_eq "chains at tip say nothing and go on" \
    "$(preflight_of 'done 3300000/3300000 done 81200/81200')" "rc=0"
assert_eq "a dashboard that cannot be read stops without the line" "$(preflight_of '')" ""
assert_eq "--skip-preflight never reads the chains: nothing" \
    "$(preflight_of 'done 1/1 syncing 1/2' 1)" "rc=0"

echo "== the heartbeat tail never repeats the line; the full-log replay is its one copy =="
harness_of() { # -> the lines run_harness printed around a detached --check run that said workers-offline
    # shellcheck disable=SC2034,SC2329  # the stubs and inputs are read by the eval'd run_harness
    (
        MODE=check BORROW_MINER=0 WORKERS=1 BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e
        RESTORE_DIR=/srv/code/pithead REMOTE_NODE_ARGS=() REMOTE_NODE_HOSTS=() IT_RIG_TOKEN="" POLLS=0
        LOG=$'  [ITEST] ── current-state check ──\n    ✗ workers online (>= 1)\ne2e-env: workers-offline'
        log() { :; }
        step() { :; }
        sleep() { :; }
        harness_install_runner() { :; }
        harness_prepare() { :; }
        harness_finished() { :; }
        on_bench() {
            case "$1" in
            *nohup*) echo 4242 ;;
            "test -f "*e2e-harness.done*)
                POLLS=$((POLLS + 1))
                [ "$POLLS" -gt 2 ]
                ;;
            "cat "*e2e-harness.done*) echo 1 ;;
            "tail -n 2 "*) printf '%s\n' "$LOG" | tail -n 2 ;;
            "cat "*e2e-harness.log*) printf '%s\n' "$LOG" ;;
            esac
        }
        eval "$HARNESS_SRC"
        run_harness
        echo "rc=$?"
    ) </dev/null 2>/dev/null | grep -a -e 'e2e-env:' -e '^rc='
}
assert_eq "two heartbeats and the replay carry the line once, indented as the replay indents" \
    "$(harness_of)" $'  e2e-env: workers-offline\nrc=1'

echo "== census: the only lines that print the key are the documented ones =="
# A new call site is a new excuse bench-ci will honour; it has to be added here, and to the key
# table in lib/e2e-env.sh, by someone who has read both.
census="$(cd "$HERE/.." && grep -rnoE '\be2e_env [a-z-]+' --include=*.sh . | grep -v '^./selftest/' |
    sed -E 's/^\.\/([^:]+):[0-9]+:e2e_env /\1 /' | LC_ALL=C sort)"
assert_eq "e2e_env call sites" "$census" "$(printf '%s\n' \
    'e2e.sh chains-behind' \
    'e2e.sh tari-not-done' \
    'lib.sh tari-sync-timeout' \
    'lib/detached-harness.sh readiness' \
    'lib/run-scenario.sh tari-not-done' \
    'lib/skip-accounting.sh workers-offline')"
assert_eq "nothing else prints the prefix" \
    "$(cd "$HERE/.." && grep -rln 'e2e-env: %s' --include=*.sh . | grep -v '^./selftest/')" "./lib/e2e-env.sh"

echo ""
echo "selftest-e2e-env: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
