#!/usr/bin/env bash
# A legitimate wizard restore re-hold must settle before the real image fixture starts.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-matrix.sh
source "$HERE/../lib/run-matrix.sh"
# shellcheck source=tests/integration/lib/run-source-image.sh
source "$HERE/../lib/run-source-image.sh"
echo "== source image prerequisite survives a restore reset and second hold =="
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

run_case() (
    CASE=$1 NOW=0 IT_FAIL=0 IT_PASS=0
    OUT_DIR="$scratch/$CASE"
    mkdir "$OUT_DIR"
    now_s() { echo "$NOW"; }
    sleep() { NOW=$((NOW + $1)); }
    # The status check already passed while the restore marker held both miners.
    wait_status_ok() { :; }
    it_step() { :; }
    capture_artifacts() { echo captured >>"$OUT_DIR/trace"; }
    timeout() {
        [ "$1" = --kill-after=2 ] && [ "$2" = 10 ] || return 2
        shift 2
        [ "$CASE" != stalled ] || return 124
        "$@"
    }
    docker() {
        [ "$*" = 'compose ps --services --status running' ] || return 2
        echo "sample:$NOW" >>"$OUT_DIR/trace"
        case "$CASE" in
        never | wait-fails-fixture-succeeds) return 0 ;;
        one)
            echo p2pool
            return 0
            ;;
        unreadable)
            printf 'p2pool\nxmrig-proxy\n'
            return 1
            ;;
        esac
        # The first release at 5s is transient; the second hold at 10s resets the streak.
        [ "$NOW" != 0 ] && [ "$NOW" != 10 ] || return 0
        printf 'p2pool\nxmrig-proxy\n'
    }
    rx() {
        case "$1" in
        'test -f dashboard/Dockerfile') [ "$CASE" != release-install ] ;;
        *lifecycle_gate_sample_target\ *)
            echo 'lifecycle-gate: before-source-image marker=present snapshot_release=false p2pool=stopped proxy=stopped'
            ;;
        *'docker compose ps --services --status running'*) eval "$1" ;;
        *'source ./pithead'*)
            echo "fixture:$NOW" >>"$OUT_DIR/trace"
            case "$CASE" in never | one | unreadable | stalled) return 1 ;; esac
            [ "$NOW" -ge 20 ] || return 1
            printf '%s\n' 'source-image: live old image differs from built declaration' \
                'Recreating xmrig-proxy: its container still uses the previous image.'
            [ "$CASE" = wrong-owner ] || echo 'source-image: guarded recreate matches declared image and Compose owner'
            echo 'source-image: original image restored'
            ;;
        *)
            echo "unexpected rx command" >&2
            return 2
            ;;
        esac
    }
    rc=0
    run_source_image_reconcile || rc=$?
    printf 'RESULT rc=%s failures=%s\n' "$rc" "$IT_FAIL"
)

for test_case in delayed never one unreadable stalled wait-fails-fixture-succeeds wrong-owner release-install; do
    run_case "$test_case" >"$scratch/$test_case.result"
    result=$(cat "$scratch/$test_case.result")
    if [ "$test_case" = release-install ]; then
        assert_contains "release install retains its by-design skip" "$result" 'RESULT rc=0 failures=0'
        assert_eq "release install performs no readiness or image I/O" "$(find "$scratch/$test_case" -type f | wc -l | tr -d ' ')" 0
        continue
    fi
    assert_eq "$test_case still executes the image fixture" "$(grep -c '^fixture:' "$scratch/$test_case/trace")" 1
    case "$test_case" in
    delayed)
        assert_contains "second hold needs two fresh running samples" "$result" 'RESULT rc=0 failures=0'
        assert_contains "image mutation begins only after the second release settles" "$(cat "$scratch/$test_case/trace")" 'fixture:20'
        assert_eq "the transient release did not satisfy the prerequisite" "$(grep -c '^sample:' "$scratch/$test_case/trace")" 5
        ;;
    wrong-owner)
        assert_contains "readiness does not suppress immutable-image/owner assertions" "$result" 'missing [source-image: guarded recreate matches declared image and Compose owner]'
        assert_contains "wrong owner still fails the fixture" "$result" 'RESULT rc=1 failures=1'
        ;;
    *)
        assert_contains "$test_case records a binding prerequisite failure" "$result" 'both services did not remain running for two consecutive samples within 1500s'
        assert_contains "$test_case captures diagnostics after failure" "$(cat "$scratch/$test_case/trace")" captured
        if [ "$test_case" = wait-fails-fixture-succeeds ]; then
            assert_contains "successful image assertions cannot erase readiness failure" "$result" 'RESULT rc=1 failures=1'
        else
            assert_contains "$test_case retains the immutable-image/owner assertion" "$result" 'missing [source-image: guarded recreate matches declared image and Compose owner]'
        fi
        ;;
    esac
done

# Exercise the actual timeout, not the stalled mock: a client ignoring TERM must be killed.
mkdir "$scratch/bin"
cat >"$scratch/bin/docker" <<'CLIENT'
#!/usr/bin/env bash
exec "$REAL_PYTHON" -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(600)'
CLIENT
chmod +x "$scratch/bin/docker"
{
    declare -f _pred_mining_probe_running
    echo 'rx() { bash -c "$1"; }'
    echo 'mining_probe_samples=1'
    echo '_pred_mining_probe_running; rc=$?'
    echo '[ "$rc" = 1 ] && [ "$mining_probe_samples" = 0 ]'
} >"$scratch/term-resistant.sh"
real_python=$(command -v python3) || exit 1
started=$(date +%s)
rc=0
PATH="$scratch/bin:$PATH" REAL_PYTHON="$real_python" \
    timeout --kill-after=2 25 bash "$scratch/term-resistant.sh" >"$scratch/term-resistant.log" 2>&1 || rc=$?
assert_rc "actual TERM-resistant Docker client is killed and rejected within the outer deadline" "$rc" 0
elapsed=$(($(date +%s) - started))
assert_num_ge "TERM-resistant client exercised the actual ten-second deadline" "$elapsed" 10
assert_num_gt "forced termination beats the outer guard" 25 "$elapsed"
[ "$IT_FAIL" -eq 0 ]
