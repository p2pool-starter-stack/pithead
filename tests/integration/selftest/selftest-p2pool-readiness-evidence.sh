#!/usr/bin/env bash
# shellcheck disable=SC2034 # fixture globals are read by extracted runtime functions
# Execute the readiness dispatch and bounded capture against a crash-looping fake target.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/p2pool-diagnostics.sh
source "$HERE/../lib/p2pool-diagnostics.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-scenario.sh
source "$HERE/../lib/run-scenario.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"
# macOS uses GNU timeout under its prefixed name.
if ! command -v timeout >/dev/null; then
    ln -s "$(command -v gtimeout)" "$TEST_DIR/bin/timeout"
fi
cat >"$TEST_DIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_CALLS"
case "$1" in
inspect)
    [ "${NO_CONTAINER:-0}" != 1 ] || exit 1
    if [ "$3" = '{{.Id}}' ]; then
        printf '%064d\n' 1
    else
        echo "id=$4 image=candidate-image status=restarting exit=139 oom_killed=false restarts=19"
    fi
    ;;
logs)
    [ "${HANG_LOGS:-0}" != 1 ] || { sleep 30; exit 1; }
    echo 'candidate panic: RPC_PASSWORD=fixture-secret'
    echo 'candidate launch --wallet fixture-wallet'
    python3 -c 'print("x" * 70000)'
    ;;
events) echo 'time=1791941645 event=die exit=139' ;;
*) exit 1 ;;
esac
DOCKER
chmod +x "$TEST_DIR/bin/docker"
export PATH="$TEST_DIR/bin:$PATH" DOCKER_CALLS="$TEST_DIR/calls"
# The actual main dispatch must capture after the bounded readiness assertion and before summary.
MAIN_SRC="$(sed -n '/^main() {$/,/^}$/p' "$HERE/../run.sh")"
eval "$MAIN_SRC"
run_fixture() { # <healthy|crash> <output directory>
    (
        OUT_DIR="$2" IT_MODE=local IT_REMOTE_DIR=. IT_PITHEAD=pithead
        READINESS=1 CHECK_ONLY=0 IT_FAIL=0 IT_PASS=0 IT_FAILED_NAMES='' FAKE_NOW=0
        # shellcheck disable=SC2034 # consumed by the real main dispatch
        IT_SSH_OPTS=()
        parse_args() { :; }
        rig_lock() { :; }
        preflight() { mkdir -p "$OUT_DIR"; }
        now_s() { echo "$FAKE_NOW"; }
        sleep() { FAKE_NOW=$((FAKE_NOW + $1)); }
        monero_caught_up() { return 0; }
        api_state() { echo '{}'; }
        jq_get() { echo 'done'; }
        env_on_box() { :; }
        box_mode() { echo 600; }
        pithead() {
            [ "$1" = status ] || return 1
            if [ "$FIXTURE_STATE" = healthy ]; then return 0; fi
            echo '  ✗ p2pool        restarting (possible crash loop — check logs)'
            return 1
        }
        rx() {
            case "$1" in *P2Pool*) bash -c "$1" ;; *) return 0 ;; esac
        }
        summary() {
            if [ "$IT_FAIL" -gt 0 ]; then
                [ -f "$OUT_DIR/readiness/p2pool-crash.txt" ] || exit 42
                return 1
            fi
        }
        FIXTURE_STATE="$1"
        main --local --readiness
    )
}
rc=0
run_fixture crash "$TEST_DIR/crash" >"$TEST_DIR/crash.log" 2>&1 || rc=$?
assert_eq 'SIGSEGV crash loop keeps readiness failed' "$rc" 1
out="$(cat "$TEST_DIR/crash/readiness/p2pool-crash.txt")"
assert_contains 'captures the failing candidate generation' "$out" 'image=candidate-image status=restarting exit=139 oom_killed=false restarts=19'
assert_contains 'failure transcript preserves evidence with a non-verdict prefix' "$(cat "$TEST_DIR/crash.log")" 'p2pool-crash: time=1791941645 event=die exit=139'
assert_contains 'retains the original exit event' "$out" 'event=die exit=139'
assert_contains 'retains panic output with password redacted' "$out" 'candidate panic: RPC_PASSWORD=<redacted>'
case "$out" in *fixture-secret* | *fixture-wallet*) it_fail 'capture masks launch secrets' ;; *) it_pass 'capture masks launch secrets' ;; esac
bytes="$(wc -c <"$TEST_DIR/crash/readiness/p2pool-crash.txt")"
[ "$bytes" -lt 83000 ] && it_pass 'capture caps log bytes' || it_fail 'capture caps log bytes' "$bytes"
# All post-lookup commands must use the captured ID, even if the name now identifies the baseline.
id="$(printf '%064d' 1)"
assert_contains 'logs pin the failing ID' "$(cat "$DOCKER_CALLS")" "logs --timestamps --tail=200 $id"
assert_contains 'events pin the failing ID' "$(cat "$DOCKER_CALLS")" "--filter container=$id"
: >"$DOCKER_CALLS"
run_fixture healthy "$TEST_DIR/healthy" >"$TEST_DIR/healthy.log" 2>&1 || exit 1
[ ! -s "$DOCKER_CALLS" ] && it_pass 'healthy readiness collects no crash evidence' || it_fail 'healthy readiness collects no crash evidence'
export NO_CONTAINER=1
rc=0
run_fixture crash "$TEST_DIR/missing" >"$TEST_DIR/missing.log" 2>&1 || rc=$?
assert_eq 'missing container cannot clear the failed verdict' "$rc" 1
assert_contains 'missing identity is explicit' "$(cat "$TEST_DIR/missing/readiness/p2pool-crash.txt")" 'P2Pool container identity unavailable'
unset NO_CONTAINER
export HANG_LOGS=1
rc=0
SECONDS=0
run_fixture crash "$TEST_DIR/hung" >"$TEST_DIR/hung.log" 2>&1 || rc=$?
assert_eq 'hung diagnostic cannot clear the failed verdict' "$rc" 1
[ "$SECONDS" -lt 12 ] && it_pass 'hung log read is bounded' || it_fail 'hung log read is bounded' "$SECONDS seconds"
assert_contains 'events still captured after log timeout' "$(cat "$TEST_DIR/hung/readiness/p2pool-crash.txt")" 'event=die exit=139'
echo "selftest-p2pool-readiness-evidence: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
