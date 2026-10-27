#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh" || exit 1
# shellcheck source=tests/integration/lib/detached-harness.sh
source "$HERE/../lib/detached-harness.sh" || exit 1
HARNESS_SRC="$(sed -n '/^run_harness() {$/,/^}$/p' "$HERE/../e2e.sh")"
[ -n "$HARNESS_SRC" ] || exit 1
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export FIXTURE_ROOT="${HERE%/tests/integration/selftest}"
export FIXTURE_EXPECTED='fixture-dashboard-42"\tail'
export FIXTURE_WORK="$scratch"
mkdir -p "$scratch/bin" "$scratch/tests/integration" "$scratch/results" "$scratch/tmp"
export IT_DASHBOARD_PASSWORD=ambient-fixture-value
cat >"$scratch/bin/awk" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
/proc/*/stat) printf '123\n' ;;
*) exec /usr/bin/awk "$@" ;;
esac
SH
for transport in nohup setsid; do
    printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' >"$scratch/bin/$transport"
done
chmod +x "$scratch/bin/"*
cat >"$scratch/tests/integration/run.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
source "$FIXTURE_ROOT/tests/integration/lib.sh" || exit 1
eval "$(sed -n '/^assert_metrics_via_caddy() {/,/^}/p' "$FIXTURE_ROOT/tests/integration/lib/run-scenario.sh")"
printf '%s\n' "$@" >>"$FIXTURE_WORK/argv"
case " $* " in
*' --readiness '*) printf 'readiness\n' >>"$FIXTURE_WORK/events"; exit 0 ;;
*' --check '*) printf 'check\n' >>"$FIXTURE_WORK/events" ;;
*) printf 'detached\n' >>"$FIXTURE_WORK/events" ;;
esac
env_on_box() {
    case "$1" in
    HOST_IP) printf dashboard.invalid ;;
    DASHBOARD_SECURE) printf true ;;
    HOST_PORT) printf 443 ;;
    DASHBOARD_AUTH_HASH_B64) printf configured ;;
    DASHBOARD_AUTH_USER) printf fixture-user ;;
    *) return 1 ;;
    esac
}
rx() {
    local auth
    printf '%s\n' "$@" >>"$FIXTURE_WORK/argv"
    auth=$(sed -n 's/^user = //p' | jq -r .) || return 1
    if [ "$auth" = "fixture-user:$FIXTURE_EXPECTED" ]; then
        printf 'pithead_up 1\n'
    else
        printf 'Unauthorized %s\n' "${IT_DASHBOARD_PASSWORD:-}"
        return 22
    fi
}
assert_metrics_via_caddy
[ "$IT_FAIL" -eq 0 ] || exit 1
[ "$IT_SKIPPED_MISSING" -eq 0 ] || exit 2
exit "${FIXTURE_EXIT:-0}"
SH
chmod +x "$scratch/tests/integration/run.sh"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
run_case() {
    local mode="$1" credential="$2" failure="$3" rc
    : >"$scratch/events"
    : >"$scratch/argv"
    : >"$scratch/commands"
    rm -f "$scratch/results/e2e-harness.done" "$scratch/.e2e-run.sh"
    (
        exec </dev/null
        export PATH="$scratch/bin:$PATH" FIXTURE_EXIT="$failure" TMPDIR="$scratch/tmp"
        export IT_DASHBOARD_PASSWORD="$credential"
        unset IT_SCRATCH_DIR
        MODE="$mode" BORROW_MINER=0 WORKERS=1 BENCH_HOST=fixture.invalid E2E_DIR="$scratch" RESTORE_DIR="$scratch"
        REMOTE_NODE_ARGS=() REMOTE_NODE_HOSTS=()
        RIG_LOCK_PARENT_ACTOR=actor RIG_LOCK_PARENT_NONCE=nonce
        HARNESS_PHASE_ARGS=" --lifecycle" SCENARIO=""
        log() { printf '%s\n' "$*"; }
        step() { printf '%s\n' "$*"; }
        warn() { printf '%s\n' "$*" >&2; }
        die() {
            printf '%s\n' "$*" >&2
            exit 1
        }
        harness_finished() { :; }
        on_bench() {
            printf '%s\n' "$1" >>"$scratch/commands"
            env -u IT_DASHBOARD_PASSWORD bash -c "$1; command_rc=\$?; wait; exit \$command_rc"
        }
        eval "$HARNESS_SRC"
        run_harness
        harness_rc=$?
        wait
        exit "$harness_rc"
    ) >"$scratch/output" 2>&1
    rc=$?
    for candidate in "$FIXTURE_EXPECTED" incorrect-fixture-value; do
        if grep -Fq -- "$candidate" "$scratch/output" "$scratch/argv" "$scratch/commands" "$scratch/.e2e-run.sh" "$scratch/results/e2e-harness.log" 2>/dev/null; then
            fail 'credential entered command, runner, log or artifact'
        fi
    done
    [ -z "$(ls -A "$scratch/tmp")" ] || fail 'harness temporary inputs survived cleanup'
    [ "$IT_DASHBOARD_PASSWORD" = ambient-fixture-value ] || fail 'dashboard credential escaped invocation scope'
    return "$rc"
}
for mode in targeted check; do
    run_case "$mode" "$FIXTURE_EXPECTED" 0 || fail "$mode lost the dashboard credential"
    grep -Fq '/metrics serves pithead_ samples through Caddy' "$scratch/results/e2e-harness.log" || fail 'authenticated metrics did not execute'
    if [ "$mode" = targeted ]; then
        [ "$(cat "$scratch/events")" = $'readiness\ncheck\ndetached' ] || fail 'pregates or later harness did not execute'
    else
        [ "$(cat "$scratch/events")" = check ] || fail 'check mode ran unexpected phases'
    fi
    for credential in '' incorrect-fixture-value; do
        run_case "$mode" "$credential" 0
        rc=$?
        [ "$rc" -ne 0 ] || fail "$mode accepted missing or incorrect credentials"
        if [ "$mode" = targeted ]; then
            [ "$(cat "$scratch/events")" = $'readiness\ncheck' ] || fail 'failed pregate reached destructive phases'
            [ ! -f "$scratch/results/e2e-harness.done" ] || fail 'failed pregate launched detached harness'
        fi
    done
done
run_case check "$FIXTURE_EXPECTED" 23
[ "$?" -eq 23 ] || fail 'detached harness status was lost'
run_case targeted $'fixture\nextra' 0
[ "$?" -ne 0 ] || fail 'newline credential was accepted'
[ ! -s "$scratch/events" ] || fail 'newline credential reached a pregate'
printf 'PASS: e2e pregates and detached harness forward credentials without argument or artifact exposure\n'
