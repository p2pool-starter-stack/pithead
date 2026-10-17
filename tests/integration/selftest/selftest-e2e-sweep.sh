#!/usr/bin/env bash
#
# Self-test for the e2e wrapper's `--harness-arg --sweep`: every scenario of the sweep plus the safety
# backup and nothing else, discoverable from the allowlist, with --mode matrix unchanged. The real
# validate_harness_args feeds the real run_harness (extracted from e2e.sh) over a stubbed bench.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/detached-harness.sh
source "$HERE/../lib/detached-harness.sh"
E2E_SRC="$HERE/../e2e.sh"

HARNESS_SRC="$(sed -n '/^run_harness() {$/,/^}$/p' "$E2E_SRC")"
assert_eq "the run_harness extraction is the whole function" \
    "$(printf '%s\n' "$HARNESS_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "run_harness() { } "

# The phase list e2e.sh launches run.sh with, or "REFUSED: <why>" when validation dies first.
phases_of() { # <mode> <borrow-miner> <wrapper-scenario> <harness-arg...>
    local mode="$1" borrow="$2" scenario="$3" lf
    shift 3
    lf="$(mktemp)"
    (
        exec </dev/null
        # shellcheck source=tests/integration/lib/harness-args.sh
        source "$HERE/../lib/harness-args.sh"
        # shellcheck disable=SC2034 # read by the validator and the eval'd run_harness
        MODE="$mode" KEEP=0 SCENARIO="$scenario" HARNESS_ARGS=("$@")
        die() {
            echo "REFUSED: $*"
            exit 1
        }
        validate_harness_args || exit 1
        # shellcheck disable=SC2034,SC2329
        BORROW_MINER="$borrow" WORKERS=1 BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e RESTORE_DIR=/srv/code/pithead-live
        # shellcheck disable=SC2034
        RIGFORGE_BOOTSTRAP_VERSION="" ROTATE_FIXTURE_ATTESTATION="" REMOTE_NODE_ARGS=() REMOTE_NODE_HOSTS=() LAUNCH_FILE="$lf"
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        harness_prepare() { HARNESS_STATE=/test/state; }
        harness_finished() { :; }
        # shellcheck disable=SC2034,SC2329 # read by the eval'd run_harness
        rig_supply() { RIG_NAME=rig-a RIG_HOST="" RIG_CONTROL_PORT=""; }
        on_bench() {
            case "$1" in
            *nohup*)
                printf '%s' "$1" >"$LAUNCH_FILE"
                cat >/dev/null
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
    ) | sed -n '/^REFUSED/p'
    sed -n 's/.*\.e2e-run\.sh[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* [^ ]* [^ ]* [^ ]* \(.*\) >\/dev\/null.*/\1/p' "$lf"
    rm -f "$lf"
}
phase_set() { # <phase-list> -> the flags, sorted, space-joined
    # shellcheck disable=SC2086  # deliberate word-splitting: the phase list is a flag string
    printf '%s\n' $1 | LC_ALL=C sort | tr '\n' ' '
}

echo "== the sweep alone: no pinned scenario, the safety backup, no other phase =="
assert_eq "targeted --sweep launches only the safety backup (and the no-mining flag)" \
    "$(phase_set "$(phases_of targeted 0 '' --sweep)")" "--no-mining-asserts --safety-backup "
assert_eq "it does not pin the preset's single scenario" \
    "$(phases_of targeted 0 '' --sweep | grep -c -- '--scenario')" "0"
assert_eq "a borrowed rig adds its identity but none of the rig phases" \
    "$(phase_set "$(phases_of targeted 1 '' --sweep)")" "--rig-name --safety-backup rig-a "
assert_eq "an explicit --safety-backup is not doubled" \
    "$(phase_set "$(phases_of targeted 0 '' --safety-backup --sweep)")" "--no-mining-asserts --safety-backup "
assert_eq "the sweep joins other hand-picked phases, in front of them" \
    "$(phase_set "$(phases_of targeted 0 '' --sweep --lifecycle)")" "--lifecycle --no-mining-asserts --safety-backup "
assert_eq "--mode matrix with the token is the same sweep" \
    "$(phase_set "$(phases_of matrix 0 '' --sweep)")" "--no-mining-asserts --safety-backup "

echo "== nothing else changes =="
assert_eq "targeted without the token still pins its scenario and runs its preset" \
    "$(phase_set "$(phases_of targeted 0 '')")" "--auth-fail-closed --lifecycle --no-mining-asserts --scenario local-pruned-main-secure-tari "
assert_eq "a hand-picked targeted phase still keeps the preset's scenario" \
    "$(phase_set "$(phases_of targeted 0 '' --hardening)")" "--hardening --no-mining-asserts --scenario local-pruned-main-secure-tari "
assert_eq "--mode matrix still means the sweep plus the destructive phases" \
    "$(phase_set "$(phases_of matrix 0 '')")" "--auth-fail-closed --fault-injection --hardening --lifecycle --no-mining-asserts --safety-backup --subnet "

echo "== a single scenario contradicts the sweep and is refused before any bench work =="
assert_contains "--harness-arg --scenario with the token" \
    "$(phases_of targeted 0 '' --sweep --scenario custom-name)" "REFUSED: --harness-arg --sweep runs every scenario"
assert_contains "the wrapper's --scenario with the token" \
    "$(phases_of matrix 0 local-pruned-main-secure-tari --sweep)" "REFUSED: --harness-arg --sweep runs every scenario"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '#!/usr/bin/env bash\n: >"$SSH_MARKER"\nexit 99\n' >"$TMP/ssh"
chmod +x "$TMP/ssh"
env PATH="$TMP:/usr/bin:/bin" SSH_MARKER="$TMP/marker" BENCH_HOST=bench MINER_HOST=rig \
    bash "$E2E_SRC" candidate --mode matrix --scenario custom-name --harness-arg --sweep >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$TMP/marker" ]; then
    it_pass "e2e.sh refuses the contradiction before it dials the bench"
else
    it_fail "e2e.sh refuses the contradiction before it dials the bench" "rc=$rc ssh_called=$([ -e "$TMP/marker" ] && echo yes || echo no)"
fi
assert_contains "the usage text names the token" "$(bash "$E2E_SRC" --help 2>&1)" "--sweep"

echo "== the allowlist advertises it =="
# The runner lists a commit's selectable phases from this arm: flags joined by pipes, then the
# line that forwards the raw flag unchanged.
advertised="$(
    python3 - "$HERE/../lib/harness-args.sh" <<'PY'
import re, sys

text = open(sys.argv[1]).read()
match = re.search(
    r"^[ \t]*((?:--[a-z][a-z0-9-]*[ \t]*\|[ \t]*)*--[a-z][a-z0-9-]*)\)[ \t]*\n"
    r'[ \t]*HARNESS_PHASE_ARGS="\$HARNESS_PHASE_ARGS \$arg"',
    text,
    re.M,
)
print(" ".join(p.strip()[2:] for p in match.group(1).split("|")) if match else "")
PY
)"
assert_contains "sweep is in the discoverable phase list" " $advertised " " sweep "
assert_contains "and the earlier phases are still there" " $advertised " " lifecycle "

printf '\npassed: %s, failed: %s\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
