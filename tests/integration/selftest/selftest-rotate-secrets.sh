#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-rotate-secrets.sh"
echo "== rotate-secrets authentication and recovery guards =="
python3 "$HERE/test_rotate_auth_probe.py" || exit 1

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
rx() { (cd "$d" && eval "$1"); }
touch "$d/config.json.bak-20260101-000000" "$d/.env.bak-20260101-000000"
_ROTATE_BAKS_BEFORE=$'config.json.bak-20260101-000000\n.env.bak-20260101-000000'
touch "$d/config.json.bak-20260102-000000" "$d/.env.bak-20260102-000000"
_rotate_cleanup_baks
assert_rc "rotation cleanup succeeds" "$?" 0
assert_eq "cleanup leaves unrelated existing recovery copies" "$(find "$d" -type f | wc -l | tr -d ' ')" 2

touch "$d/config.json.bak-20260102-000000" "$d/.env.bak-20260102-000000"
_SAFETY_RESTORE_ARMED=1
safety_abort_restore() { :; }
_rotate_abort_restore
assert_eq "an unverified interrupted restore retains rotation recovery copies" "$(find "$d" -type f | wc -l | tr -d ' ')" 4
safety_abort_restore() { _SAFETY_RESTORE_ARMED=0; }
_rotate_abort_restore
assert_eq "a verified interrupted restore cleans only this rotation's recovery copies" "$(find "$d" -type f | wc -l | tr -d ' ')" 2
assert_rc "missing cleanup inventory cannot silently pass" "$(
    rx() { return 1; }
    _rotate_cleanup_baks
    echo $?
)" 1

curl() {
    cat >"$d/curl-config"
    [ "$CURL_RESULT" != offline ] || return 7
    printf '{"status":"OK"}\n%s' "$CURL_RESULT"
}
rx() { (cd "$d" && eval "$1"); }
for status in 200 401 offline; do
    CURL_RESULT="$status"
    result="$(_rotate_monero_rpc_probe test-user test-password)"
    case "$status" in
    200) expected=rpc-ok ;;
    401) expected=rpc-refused ;;
    *) expected=rpc-fail ;;
    esac
    assert_eq "RPC $status produces an explicit authentication verdict" "$result" "$expected"
done
assert_contains "RPC credentials arrive through curl config stdin" "$(cat "$d/curl-config")" test-user:test-password

export RIG_NAME=selected
rx() { printf '%s' '{"workers":[["other","unused",1,99],["selected","unused",1,0]]}'; }
_rotate_proxy_accepted_after 0
assert_rc "another worker's accepted share cannot prove the reserved rig reconnected" "$?" 1
rx() { printf '%s' '{"workers":[["selected","unused",1,1]]}'; }
_rotate_proxy_accepted_after 0
assert_rc "the selected rig's new accepted share proves reconnection" "$?" 0

# The remote command itself is evaluated; undefined quote_arg on the target cannot hide.
env_on_box() { printf '%s' "$d/pool"; }
mkdir -p "$d/pool/stats/local"
printf '%s' '{"zmq_last_active":0}' >"$d/pool/stats/local/p2p"
rx() { eval "$1"; }
_rotate_p2pool_monero_live "$(($(date +%s) - 1))"
assert_rc "fresh post-rotation Monero ZMQ evidence is accepted" "$?" 0
printf '%s' '{"zmq_last_active":100}' >"$d/pool/stats/local/p2p"
_rotate_p2pool_monero_live "$(($(date +%s) - 1))"
assert_rc "pre-rotation ZMQ activity is rejected even with a fresh stats file" "$?" 1

source "$HERE/../lib/detached-harness.sh"
E2E_DIR="$d"
CI_RIG_RECOVERY_HOLD=1
on_bench() { cat >"$d/runner.sh"; }
harness_install_runner
assert_contains "the detached runner forwards the persistent-hold capability" "$(cat "$d/runner.sh")" 'export CI_RIG_RECOVERY_HOLD=1'

# Drive the REAL phase, controller handshake and safety EXIT trap against local files. Only
# daemon/SSH endpoints are substituted; no container, service, miner or network is used.
drive_phase() { # <fixture dir> <success|restore-failure|interrupted>
    (
        local fixture="$1" failure="$2"
        source "$HERE/../lib/borrow-fixture.sh"
        source "$HERE/../lib/borrow-rearm.sh"
        source "$HERE/../lib/run-safety.sh"
        export RIG_NAME=selected CI_RIG_RECOVERY_HOLD=1 WORKERS=1 BENCH_HOST=bench.example
        export E2E_DIR="$fixture" MINER_XMRIG_CONFIG="$fixture/miner.json" MINER_ROTATE_CFG_BACKUP=""
        IT_BORROW_REARM_REQUEST="$fixture/request" IT_BORROW_REARM_ACK="$fixture/ack" IT_BORROW_REARM_TOKEN=run-123
        printf '%s' '{"p2pool":{"stratum_password":"auto"}}' >"$fixture/config.json"
        printf '%s\n' PROXY_AUTH_TOKEN=old-token PROXY_STRATUM_PASSWORD=old-pass >"$fixture/.env"
        printf '%s' '{"pools":[{"url":"bench.example:3333","pass":"original"}]}' >"$fixture/miner.json"
        cp "$fixture/.env" "$fixture/original.env"
        touch "$fixture/safety" "$fixture/runner-hold"
        export SAFETY_ARCHIVE="$fixture/safety" SAFETY_RESTORE_FAILED=0 _SAFETY_RESTORE_ARMED=1 _SAFETY_FOREIGN_TRAP=""
        export KEEP_STATE=0 SKIP_MINING_ASSERTS=1 EXPECTED_WORKERS=1
        BASELINE_CONFIG="$(cat "$fixture/config.json")"
        export BASELINE_CONFIG
        secret_fingerprint() { cksum <"$fixture/.env"; }
        upgrade_secret_fingerprints() { secret_fingerprint; }
        BASELINE_SECRET_FP="$(secret_fingerprint)" BASELINE_EXACT_SECRET_FP="$BASELINE_SECRET_FP"
        export BASELINE_EXACT_SECRET_FP
        rx() { (cd "$fixture" && eval "$1"); }
        on_bench() { eval "$1"; }
        on_miner() { eval "$1"; }
        env_on_box() { sed -n "s/^$1=//p" "$fixture/.env"; }
        step() { :; }
        warn() { :; }
        wait_workers() { return 0; }
        miner_reload() { return 0; }
        miner_service_active() {
            [ "$failure" != restore-failure ] || [ "$(jq -r '.pools[0].pass' "$fixture/miner.json")" != original ]
        }
        baseline_up() { return 0; }
        wait_status_ok() { return 0; }
        _rotate_proxy_token_accepted() { return 0; }
        _rotate_proxy_live_args() { printf '%s' new-pass; }
        _rotate_proxy_upstream_active() { return 0; }
        _rotate_p2pool_monero_live() { return 0; }
        _rotate_stratum_auth() { return 0; }
        _rotate_rig_accepted() {
            local count
            count="$(cat "$fixture/count" 2>/dev/null || echo 0)"
            printf '%s' "$count"
            printf '%s' "$((count + 1))" >"$fixture/count"
        }
        pithead() {
            case "$1" in
            rotate-secrets)
                cp "$fixture/config.json" "$fixture/config.json.bak-20260102-000000"
                cp "$fixture/.env" "$fixture/.env.bak-20260102-000000"
                chmod 600 "$fixture/"*bak-* "$fixture/.env.bak-20260102-000000"
                printf '%s\n' PROXY_AUTH_TOKEN=new-token PROXY_STRATUM_PASSWORD=new-pass >"$fixture/.env"
                ;;
            restore)
                [ "$failure" = success ] || return 1
                cp "$fixture/original.env" "$fixture/.env"
                ;;
            esac
            return 0
        }
        wait_for() {
            shift 3
            if [ "$1" = _borrow_rearm_ack_matches ]; then
                handle_borrow_rearm "$IT_BORROW_REARM_REQUEST" "$IT_BORROW_REARM_ACK" "$IT_BORROW_REARM_TOKEN" || return 1
                if [ "$failure" = interrupted ] && [[ "$IT_BORROW_REARM_EXPECTED" == *' rotate-stratum '* ]]; then
                    kill -TERM "$BASHPID"
                fi
            fi
            "$@"
        }
        trap 'exit 130' TERM
        run_rotate_secrets >/dev/null 2>&1
        exit "$?"
    )
}
for scenario in success restore-failure interrupted; do
    mkdir "$d/$scenario"
    drive_phase "$d/$scenario" "$scenario"
    phase_rc=$?
    if [ "$scenario" = success ]; then
        assert_rc "the complete successful phase verifies its restoration" "$phase_rc" 0
        assert_eq "successful phase prunes its verified borrowed-rig anchor" "$(find "$d/$scenario" -name '*.e2e-rotate.*' | wc -l | tr -d ' ')" 0
        assert_eq "successful phase removes its rotation safety copies" "$(find "$d/$scenario" -name '*.bak-*' | wc -l | tr -d ' ')" 0
    else
        assert_eq "$scenario fails the complete phase" "$([ "$phase_rc" -ne 0 ] && echo failed)" failed
        assert_eq "$scenario retains the borrowed-rig recovery anchor" "$(find "$d/$scenario" -name '*.e2e-rotate.*' | wc -l | tr -d ' ')" 1
        assert_eq "$scenario retains the safety archive and runner-owned hold" "$(test -f "$d/$scenario/safety" && test -f "$d/$scenario/runner-hold" && echo retained)" retained
        assert_eq "$scenario retains owner-only rotation safety copies" "$(find "$d/$scenario" -name '*.bak-*' | wc -l | tr -d ' ')" 2
    fi
done

echo "selftest-rotate-secrets: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
