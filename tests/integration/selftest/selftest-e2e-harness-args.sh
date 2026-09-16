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
# selftest-e2e-boundary.sh; this file only proves run_harness appends whatever it is handed.
launch_of() { # <harness-phase-args> -> the raw launch command string
    local lf sf
    lf="$(mktemp)" sf="$(mktemp)"
    # shellcheck disable=SC2034,SC2329
    (
        exec </dev/null
        MODE=targeted BORROW_MINER=0 WORKERS=1 BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e RESTORE_DIR=/srv/code/pithead-live
        SCENARIO="" RIGFORGE_BOOTSTRAP_VERSION="" HARNESS_PHASE_ARGS="$1"
        REMOTE_NODE_ARGS=() REMOTE_NODE_HOSTS=()
        LAUNCH_FILE="$lf" STDIN_FILE="$sf"
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        die() { exit 1; }
        harness_prepare() { HARNESS_STATE=/test/state; }
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

echo "== --harness-arg lands AFTER the mode's own flags, unchanged (#2179) =="
BASE="$(phase_list_of "$(launch_of "")")"
WITH_ARG="$(phase_list_of "$(launch_of " --hardening")")"
assert_eq "targeted's own phases are unaffected by an empty HARNESS_PHASE_ARGS" \
    "$(has_phase "$BASE" --hardening)" "no"
assert_eq "a supplied phase joins the launch" "$(has_phase "$WITH_ARG" --hardening)" "yes"
assert_eq "it lands strictly AFTER the mode's own flags, not before" \
    "$(printf '%s\n' "$WITH_ARG" | grep -oE -- '--(lifecycle|hardening)' | tr '\n' ' ')" \
    "--lifecycle --hardening "
assert_eq "a --scenario NAME pair supplied by validate_harness_args reaches run.sh verbatim" \
    "$(has_phase "$(phase_list_of "$(launch_of " --scenario custom-name")")" custom-name)" "yes"

echo ""
echo "selftest-e2e-harness-args: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
