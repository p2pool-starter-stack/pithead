#!/usr/bin/env bash
# Regression: a second sync-gate hold between initial release and moved-subnet UID/TLS probes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-matrix.sh
source "$HERE/../lib/run-matrix.sh"
# shellcheck source=tests/integration/lib/run-state.sh
source "$HERE/../lib/run-state.sh"

echo "== moved-subnet probes recheck a second mining-service hold =="
SCRATCH="$(mktemp -d)" || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
# Keep the binding comparison implementations when stubbing unrelated battery rows.
eval "$(declare -f assert_eq | sed '1s/assert_eq/probe_assert_eq/')"
eval "$(declare -f assert_ne | sed '1s/assert_ne/probe_assert_ne/')"

run_case() (
    CASE="$1"
    NOW=0
    IT_FAIL=0
    EXPECTED_WORKERS=1
    SKIP_MINING_ASSERTS=1
    BASELINE_SECRET_FP=fixture
    printf 'initial\n' >"$SCRATCH/stage"
    : >"$SCRATCH/probes"
    jq_get() {
        case "$2" in
        .monero.mode) [ "$1" = config ] && echo local || echo Pruned ;;
        .tari.mode) echo local ;;
        .p2pool.stratum_tls) echo true ;;
        .monero.view_key | .tari.view_key) ;;
        *) echo false ;;
        esac
    }
    clearnet_flag_effective() { echo false; }
    now_s() { echo "$NOW"; }
    sleep() { NOW=$((NOW + $1)); }
    it_step() { :; }
    it_warn() { :; }
    timeout() {
        [ "$1" = 10 ] || return 2
        shift
        [ "$CASE" != stalled ] || return 124
        "$@"
    }
    docker() {
        [ "$*" = 'compose ps --services --status running' ] || return 2
        local stage
        stage="$(cat "$SCRATCH/stage")"
        if [ "$stage" != initial ]; then
            case "$CASE" in
            never) return 0 ;;
            one)
                echo p2pool
                return 0
                ;;
            unreadable)
                printf 'p2pool\nxmrig-proxy\n'
                return 1
                ;;
            *)
                # Briefly running, held again at 5s, then released at 10s.
                if [ "$NOW" -eq 5 ]; then return 0; fi
                ;;
            esac
        fi
        printf 'p2pool\nxmrig-proxy\n'
    }
    rx() {
        case "$1" in
        *'docker compose ps --services --status running'*) eval "$1" ;;
        'docker exec '*' id -u')
            printf '%s\n' "$1" >>"$SCRATCH/probes"
            if [[ "$1" == *p2pool* || "$1" == *xmrig-proxy* ]]; then
                case "$CASE" in never | one | unreadable | stalled) return 1 ;; esac
                [ "$NOW" -ge 15 ] || return 1
                [ "$CASE" != wrong-uid ] || {
                    echo 0
                    return 0
                }
            fi
            case "$1" in *'exec tor '*) echo 100 ;; *'exec caddy '* | *'exec docker-'*) echo 0 ;; *) echo 1000 ;; esac
            ;;
        *'openssl s_client'*)
            echo TLS >>"$SCRATCH/probes"
            case "$CASE" in never | one | unreadable | stalled) return 1 ;; esac
            [ "$NOW" -ge 15 ] && echo served
            ;;
        *'openssl x509 -in'*) [ "$CASE" = wrong-cert ] && echo other || echo served ;;
        *'HostConfig.Dns'*) echo '[127.0.0.1]' ;;
        *'json .Args'*) echo '--donate-level=0' ;;
        *) echo 1 ;;
        esac
    }
    running_services() { docker compose ps --services --status running; }
    expected_services() { printf 'p2pool\nxmrig-proxy\n'; }
    pithead() { :; }
    api_state() { echo '{}'; }
    monero_caught_up() { return 0; }
    env_on_box() { echo false; }
    expected_topology_nodes() { :; }
    secret_fingerprint() { echo fixture; }
    assert_onion_targets() { :; }
    assert_zmq_publishes() { :; }
    zmq_pub_probe() { :; }
    assert_mergemine_roundtrip() { :; }
    assert_pool_type() { :; }
    assert_mining_state() { :; }
    assert_egress_dial_pair() { :; }
    assert_num_ge() { :; }
    assert_contains() { :; }
    assert_rc() { :; }
    assert_num_gt() {
        if [[ "$1" == 'memory ceiling live on dashboard '* ]]; then
            echo UID >"$SCRATCH/stage"
            NOW=0
        fi
    }
    it_pass() {
        # Inject a distinct later hold immediately before TLS as well as the UID hold.
        if [[ "$1" == 'default-off stratum: '* ]]; then
            echo TLS >"$SCRATCH/stage"
            NOW=0
        fi
        printf 'PASS %s\n' "$1"
    }
    assert_eq() {
        case "$1" in 'runtime uid '* | 'live-served cert '*) probe_assert_eq "$@" ;; esac
    }
    assert_ne() { probe_assert_ne "$@"; }
    # Unrelated waits are cheap stubs; the new prerequisite uses the real bounded waiter.
    eval "$(declare -f wait_for | sed '1s/wait_for/probe_wait_for/')"
    wait_for() {
        case "$3" in 'mining services running before '*) probe_wait_for "$@" ;; *) return 0 ;; esac
    }
    assert_running_state subnet config
    printf 'FAILURES %s\n' "$IT_FAIL"
)

for test_case in delayed never one unreadable stalled wrong-uid wrong-cert; do
    run_case "$test_case" >"$SCRATCH/result"
    result="$(cat "$SCRATCH/result")"
    assert_eq "$test_case still executes both mining UID probes" \
        "$(grep -Ec 'docker exec (p2pool|xmrig-proxy) id -u' "$SCRATCH/probes")" 2
    assert_eq "$test_case still executes the TLS handshake" "$(grep -c '^TLS$' "$SCRATCH/probes")" 1
    case "$test_case" in
    delayed)
        assert_contains "a second hold releases before UID and TLS reads" "$result" 'FAILURES 0'
        assert_eq "all three fresh prerequisites passed" \
            "$(grep -c '^PASS mining services running before subnet ' "$SCRATCH/result")" 3
        ;;
    never | one | unreadable | stalled)
        assert_eq "$test_case reports all three prerequisite failures" \
            "$(grep -c '✗ mining services running before subnet ' "$SCRATCH/result")" 3
        assert_contains "$test_case retains the UID assertion" "$result" 'expected [1000], got []'
        assert_contains "$test_case retains the TLS assertion" "$result" 'expected not []'
        ;;
    wrong-uid) assert_contains "released root miners still fail UID assertions" "$result" 'expected [1000], got [0]' ;;
    wrong-cert) assert_contains "released mismatched certificate still fails" "$result" 'expected [other], got [served]' ;;
    esac
done

[ "$IT_FAIL" -eq 0 ]
