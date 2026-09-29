#!/usr/bin/env bash
# Self-test e2e.sh's --harness-arg (#2179): bench-ci#46 forwards one hand-picked run.sh phase this
# way. Standalone, same reasoning as selftest-e2e-phases.sh — kept off selftest-e2e-phases.sh's own
# file-budget ceiling. Run directly, or via `make test-integration-selftest`. No server, no bench.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/detached-harness.sh  # run_harness's REAL collaborators
source "$HERE/../lib/detached-harness.sh"
E2E_SRC="$HERE/../e2e.sh"

HARNESS_SRC="$(sed -n '/^run_harness() {$/,/^}$/p' "$E2E_SRC")"
assert_eq "the extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$HARNESS_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "run_harness() { } "

# Drives run_harness with HARNESS_PHASE_ARGS set directly, the way validate_harness_args
# (lib/harness-args.sh) would leave it — that function's OWN allowlist/quoting is covered by
# selftest-e2e-boundary.sh; this file proves what run_harness launches with what it is handed.
launch_of() { # <harness-phase-args> [borrow-miner] [mode] [scenario] [harness-scenario-args] -> the raw launch command string
    local lf sf
    lf="$(mktemp)" sf="$(mktemp)"
    # shellcheck disable=SC2034,SC2329
    (
        exec </dev/null
        MODE="${3:-targeted}" BORROW_MINER="${2:-0}" WORKERS=1 BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e RESTORE_DIR=/srv/code/pithead-live
        SCENARIO="${4:-}" RIGFORGE_BOOTSTRAP_VERSION="" HARNESS_PHASE_ARGS="$1" HARNESS_SCENARIO_ARGS="${5:-}"
        REMOTE_NODE_ARGS=() REMOTE_NODE_HOSTS=()
        LAUNCH_FILE="$lf" STDIN_FILE="$sf"
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        die() { exit 1; }
        harness_prepare() { HARNESS_STATE=/test/state; }
        rig_supply() { RIG_NAME=rig-a RIG_HOST="" RIG_CONTROL_PORT=""; }
        harness_finished() { :; }
        on_bench() {
            case "$1" in
            *nohup*)
                printf '%s' "$1" >"$LAUNCH_FILE"
                cat >"$STDIN_FILE"
                echo 4242
                ;;
            *e2e-harness.done*)
                echo 0
                return 0
                ;;
            esac
            return 0
        }
        eval "$HARNESS_SRC"
        run_harness >/dev/null 2>&1
        :
    ) </dev/null
    cat "$lf"
    rm -f "$lf" "$sf"
}

has_phase() { # <phase-list> <flag> -> "yes" | "no"
    case " $1 " in *" $2 "*) echo yes ;; *) echo no ;; esac
}

phase_list_of() { # <launch-cmd> -> the phase list run.sh was launched with
    printf '%s\n' "$1" | sed -n 's/.*\.e2e-run\.sh[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* [^ ]* [^ ]* [^ ]* \(.*\) >\/dev\/null.*/\1/p'
}

echo "== hand-picked phases replace the preset, keeping its setup (#2179, bench-ci#878) =="
BASE="$(phase_list_of "$(launch_of "")")"
WITH_ARG="$(phase_list_of "$(launch_of " --hardening")")"
assert_eq "targeted's own phases are unaffected by an empty HARNESS_PHASE_ARGS" \
    "$(has_phase "$BASE" --lifecycle)|$(has_phase "$BASE" --auth-fail-closed)|$(has_phase "$BASE" --hardening)" "yes|yes|no"
assert_eq "a supplied phase joins the launch" "$(has_phase "$WITH_ARG" --hardening)" "yes"
assert_eq "it replaces the preset's phases, so none of them can skip it" \
    "$(has_phase "$WITH_ARG" --lifecycle)|$(has_phase "$WITH_ARG" --auth-fail-closed)" "no|no"
assert_eq "the preset's scenario stays, or run.sh would sweep the whole matrix" \
    "$(has_phase "$WITH_ARG" local-pruned-main-secure-tari)" "yes"
RIG_BASE="$(phase_list_of "$(launch_of "" 1)")"
RIG_ARG="$(phase_list_of "$(launch_of " --hardening" 1)")"
RIG_PICK="$(phase_list_of "$(launch_of " --rigforge-control" 1)")"
assert_eq "a borrowed rig adds the rig phases to a preset run" \
    "$(has_phase "$RIG_BASE" --rigforge)|$(has_phase "$RIG_BASE" --rigforge-control)" "yes|yes"
assert_eq "a hand-picked run drops the unrequested rig phases but keeps the rig identity" \
    "$(has_phase "$RIG_ARG" --rigforge)|$(has_phase "$RIG_ARG" --rigforge-control)|$(has_phase "$RIG_ARG" rig-a)|$(has_phase "$RIG_ARG" --hardening)" \
    "no|no|yes|yes"
assert_eq "a hand-picked rig phase runs, once" \
    "$(printf '%s\n' "$RIG_PICK" | grep -o -- '--rigforge-control' | wc -l | tr -d ' ')" "1"
assert_eq "a --scenario NAME pair supplied by validate_harness_args reaches run.sh verbatim" \
    "$(has_phase "$(phase_list_of "$(launch_of "" 0 targeted "" " --scenario custom-name")")" custom-name)" "yes"
RIG_SCENARIO="$(phase_list_of "$(launch_of "" 1 targeted "" " --scenario custom-name")")"
assert_eq "a scenario-only modifier keeps targeted and borrowed-rig phases" \
    "$(has_phase "$RIG_SCENARIO" --auth-fail-closed)|$(has_phase "$RIG_SCENARIO" --lifecycle)|$(has_phase "$RIG_SCENARIO" --rigforge)|$(has_phase "$RIG_SCENARIO" --rigforge-control)|$(has_phase "$RIG_SCENARIO" custom-name)" \
    "yes|yes|yes|yes|yes"
MATRIX_BASE="$(phase_list_of "$(launch_of "" 0 matrix local-pruned-main-secure-tari)")"
MATRIX_ARG="$(phase_list_of "$(launch_of " --hardening" 0 matrix local-pruned-main-secure-tari)")"
MATRIX_SCENARIO="$(phase_list_of "$(launch_of "" 1 matrix "" " --scenario custom-name")")"
assert_eq "matrix keeps its preset without a hand-picked phase" \
    "$(has_phase "$MATRIX_BASE" --safety-backup)|$(has_phase "$MATRIX_BASE" --lifecycle)|$(has_phase "$MATRIX_BASE" --auth-fail-closed)" "yes|yes|yes"
assert_eq "a hand-picked matrix phase replaces its preset but keeps the scenario" \
    "$(has_phase "$MATRIX_ARG" --hardening)|$(has_phase "$MATRIX_ARG" --lifecycle)|$(has_phase "$MATRIX_ARG" --fault-injection)|$(has_phase "$MATRIX_ARG" --auth-fail-closed)|$(has_phase "$MATRIX_ARG" --subnet)|$(has_phase "$MATRIX_ARG" --safety-backup)|$(has_phase "$MATRIX_ARG" local-pruned-main-secure-tari)" \
    "yes|no|no|no|no|no|yes"
assert_eq "a scenario-only modifier keeps matrix and borrowed-rig phases" \
    "$(has_phase "$MATRIX_SCENARIO" --safety-backup)|$(has_phase "$MATRIX_SCENARIO" --lifecycle)|$(has_phase "$MATRIX_SCENARIO" --rigforge)|$(has_phase "$MATRIX_SCENARIO" --rigforge-control)|$(has_phase "$MATRIX_SCENARIO" custom-name)" \
    "yes|yes|yes|yes|yes"

echo ""
echo "selftest-e2e-harness-args: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
