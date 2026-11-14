#!/usr/bin/env bash
# Exercise the real wrapper transport through the skipped RigForge-control handshake.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/detached-harness.sh
source "$HERE/../lib/detached-harness.sh"
# shellcheck source=tests/integration/lib/borrow-rearm.sh
source "$HERE/../lib/borrow-rearm.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-rig-control.sh
source "$HERE/../lib/run-rig-control.sh"

E2E_SRC="$HERE/../e2e.sh"
RUN_SRC="$HERE/../run.sh"
HARNESS_SRC="$(sed -n '/^run_harness() {$/,/^}$/p' "$E2E_SRC")"
MAIN_SRC="$(sed -n '/^main() {$/,/^}$/p' "$RUN_SRC")"
assert_eq "run_harness extraction opens and closes" \
    "$(printf '%s\n' "$HARNESS_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "run_harness() { } "
assert_eq "main extraction opens and closes" \
    "$(printf '%s\n' "$MAIN_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "main() { } "
assert_contains "real main dispatches RigForge control before re-arm" "$MAIN_SRC" \
    'run_rigforge_control || rig_control_ok=0'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/e2e/results" "$WORK/live"

capture_transport() {
    local rest value i
    rest="${1#*./.e2e-run.sh }"
    for i in 1 2 3 4; do
        rest="${rest#\'}"
        value="${rest%%\'*}"
        rest="${rest#*\'}"
        rest="${rest# }"
    done
    for i in 1 2 3; do
        rest="${rest#\'}"
        value="${rest%%\'*}"
        printf '%s%s' "$value" "$([ "$i" = 3 ] || printf '|')"
        rest="${rest#*\'}"
        rest="${rest# }"
    done
}

transport_of() { # <borrow-miner>
    local record="$WORK/transport.$1"
    if ! (
        # shellcheck disable=SC2034,SC2329
        MODE=targeted BORROW_MINER="$1" WORKERS=1 BENCH_HOST="" E2E_DIR="$WORK/e2e" RESTORE_DIR="$WORK/live"
        # shellcheck disable=SC2034
        SCENARIO="" RIGFORGE_BOOTSTRAP_VERSION="" HARNESS_PHASE_ARGS=" --rigforge-control" HARNESS_SCENARIO_ARGS="" \
            RIG_NAME="" RIG_HOST="" RIG_CONTROL_PORT="" ROTATE_FIXTURE_ATTESTATION="" \
            REMOTE_NODE_ARGS=() REMOTE_NODE_HOSTS=()
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        die() { exit 1; }
        rig_supply() { RIG_NAME=rig; }
        harness_install_runner() { :; }
        harness_pregate() { :; }
        harness_prepare() { HARNESS_STATE="$WORK/state"; }
        harness_finished() { :; }
        on_bench() {
            case "$1" in
            *nohup*)
                capture_transport "$1" >"$record"
                printf '%s' "$1" >"$record.launch"
                cat >/dev/null
                echo 42
                ;;
            *borrow-rearm.*.request*) return 1 ;;
            *e2e-harness.done*) echo 0 ;;
            *e2e-harness.log*) return 0 ;;
            *) return 1 ;;
            esac
        }
        eval "$HARNESS_SRC"
        run_harness >/dev/null 2>&1
    ); then
        return 1
    fi
    [ -f "$record" ] || return 1
    cat "$record"
}

drive_main() { # <request|ack|token> <ack|missing|stale>
    local transport="$1" ack_mode="$2" request ack token rc waits=0
    IFS='|' read -r request ack token <<<"$transport"
    [ -z "$request" ] || rm -f "$request" "$ack"
    (
        IT_PASS=0 IT_FAIL=0 IT_FAILED_NAMES="" IT_SKIPPED_PHASES=0
        IT_SKIPPED_NAMES="" IT_SKIPPED_MISSING=0 IT_SKIPPED_BY_DESIGN=0 IT_SKIPPED_COVERED=0
        IT_MODE=local IT_REMOTE_DIR="$WORK/live" IT_BORROW_REARM_REQUEST="$request"
        IT_BORROW_REARM_ACK="$ack" IT_BORROW_REARM_TOKEN="$token" RIG_NAME="" RIG_HOST=""
        RIG_LOCK_PARENT_ACTOR="" RIG_LOCK_PARENT_NONCE="" IT_SCRATCH_DIR=""
        # shellcheck disable=SC2034
        READINESS=0 CHECK_ONLY=0 ONLY_SCENARIO="" SAFETY_ARCHIVE="" SAFETY_RESTORE_FAILED=0 \
            _SAFETY_RESTORE_ARMED=0 _UPGRADE_RESTORE_ARMED=0 RUN_IMAGE_UPGRADE=0 \
            RUN_RIGFORGE_CONTROL=1 RUN_RIGFORGE=0 RUN_LIFECYCLE=0 RUN_FAULTS=0 RUN_ROTATE_SECRETS=0 \
            RUN_AUTH_FAIL_CLOSED=0 RUN_HARDENING=0 RUN_ROTATE_ONION=0 RUN_XVB_ROUTING=0 \
            RUN_ALERT_EGRESS=0 RUN_MERGEMINE_SUBMIT=0 RUN_TARI_STRANDED=0 RUN_MONERO_STRANDED=0 \
            RUN_MERGEMINE_LOCALNET=0 RUN_SUBNET=0 LIFECYCLE_STACK_INTACT=0
        parse_args() { :; }
        rig_lock() { :; }
        preflight() { :; }
        safety_backup() { return 0; }
        hugepages_begin() { :; }
        scenario_matrix() { :; }
        has_compose_profile() { return 0; }
        env_on_box() { :; }
        api_state() { printf '%s' '{"workers":[]}'; }
        safety_rollback_if_failed() { :; }
        restore_baseline() { :; }
        safety_cleanup() { :; }
        hugepages_finish() { :; }
        summary() { [ "$IT_FAIL" -eq 0 ]; }
        wait_for() {
            waits=$((waits + 1))
            shift 3
            case "$ack_mode" in
            ack) printf '%s' "$IT_BORROW_REARM_EXPECTED" >"$IT_BORROW_REARM_ACK" ;;
            stale) printf '%s' stale >"$IT_BORROW_REARM_ACK" ;;
            esac
            "$@"
        }
        eval "$MAIN_SRC"
        main >/dev/null 2>&1
        rc=$?
        printf '%s|%s|%s|%s|%s\n' "$rc" "$IT_FAIL" \
            "$([ -n "$request" ] && [ -f "$request" ] && echo yes || echo no)" "$IT_SKIPPED_PHASES" "$waits"
    )
}

echo "== wrapper transport reaches the skipped real RigForge-control phase =="
if ! NO_MINER="$(transport_of 0)"; then
    it_fail "targeted no-miner wrapper launch is captured" "run_harness failed before launch"
    exit 1
fi
if ! BORROWED="$(transport_of 1)"; then
    it_fail "targeted borrowed wrapper launch is captured" "run_harness failed before launch"
    exit 1
fi
assert_contains "targeted no-miner launch keeps the requested control phase" \
    "$(cat "$WORK/transport.0.launch")" "--rigforge-control"
assert_contains "targeted no-miner launch disables mining assertions" \
    "$(cat "$WORK/transport.0.launch")" "--no-mining-asserts"
assert_eq "no-miner transport has empty request and ack paths but keeps its launch id" \
    "$(printf '%s' "$NO_MINER" | awk -F'|' '{print ($1 == "" && $2 == "" && $3 != "") ? "yes" : "no"}')" "yes"
assert_eq "skipped no-miner RigForge control succeeds without waiting or requesting" \
    "$(drive_main "$NO_MINER" missing)" "0|0|no|1|0"

echo "== borrowed transport remains binding =="
assert_eq "borrowed transport retains request, ack, and token" \
    "$(printf '%s' "$BORROWED" | awk -F'|' '{print ($1 != "" && $2 != "" && $3 != "") ? "yes" : "no"}')" "yes"
assert_eq "acknowledged borrowed re-arm succeeds" "$(drive_main "$BORROWED" ack)" "0|0|yes|1|1"
assert_eq "missing borrowed acknowledgement fails" "$(drive_main "$BORROWED" missing)" "1|1|yes|1|1"
assert_eq "stale borrowed acknowledgement fails" "$(drive_main "$BORROWED" stale)" "1|1|yes|1|1"

echo "== named actions without transport remain fail closed =="
assert_rc "an action without controller transport fails closed" "$(
    IT_BORROW_REARM_REQUEST=""
    it_fail() { :; }
    wait_borrow_rearm rotate-stratum
    echo $?
)" 1

echo "selftest-e2e-no-miner: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
