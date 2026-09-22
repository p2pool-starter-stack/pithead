#!/usr/bin/env bash
# The tier-4 load worker is opt-in and must remain one-threaded, baseline-relative,
# and cleanup-safe. This source-level contract is the cheap guard; the live leg proves XMRig.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../e2e.sh"
LOAD_SRC="$HERE/../lib/load-worker.sh"
worker_src="$(sed -n '/^worker_names() {$/,/^}$/p' "$LOAD_SRC")"
borrowed_src="$(sed -n '/^refresh_load_borrowed_name() {$/,/^}$/p' "$LOAD_SRC")"
wait_src="$(sed -n '/^wait_load_workers() {/,/^}$/p' "$LOAD_SRC")"
cleanup_src="$(sed -n '/^cleanup_stale_load_workers() {$/,/^}$/p' "$LOAD_SRC")"
load_src="$(sed -n '/^start_load_worker() {$/,/^}$/p' "$LOAD_SRC")"
verify_src="$(sed -n '/^verify_load_worker() {$/,/^}$/p' "$LOAD_SRC")"
stop_src="$(sed -n '/^stop_load_worker() {$/,/^}$/p' "$LOAD_SRC")"
sample_src="$(sed -n '/^sample_load_worker() {$/,/^}$/p' "$LOAD_SRC")"
restore_src="$(sed -n '/^restore_all() {$/,/^}$/p' "$SRC")"
borrow_src="$(sed -n '/^borrow_miner() {$/,/^}$/p' "$SRC")"
run_src="$(sed -n '/^run_harness() {$/,/^}$/p' "$SRC")"
main_src="$(sed -n '/^main() {$/,/^}$/p' "$SRC")"

echo "== selftest: load worker stays opt-in, capped, capacity-relative, and cleanup-safe =="
case "$worker_src" in *'select(.status == \"online\")'*'[^[:cntrl:]]+'*) ;; *) exit 1 ;; esac
case "$borrowed_src" in *'.pools[0].user'*'[^[:cntrl:]]+'*) ;; *) exit 1 ;; esac
case "$load_src" in *'[ "$WORKERS" -eq 3 ]'*) ;; *) exit 1 ;; esac
case "$load_src" in *'--threads=1'*) ;; *) exit 1 ;; esac
case "$load_src" in *'umask 077'*'mktemp -d'*) ;; *) exit 1 ;; esac
case "$load_src" in *'cleanup_stale_load_workers'*'mktemp -d'*) ;; *) exit 1 ;; esac
case "$load_src" in *'owned()'*'cleanup-failed'*'kill -KILL'*'trap fail EXIT'*) ;; *) exit 1 ;; esac
case "$load_src" in *'test -z'*'wait'*'rm -rf --'*) ;; *) exit 1 ;; esac
case "$load_src" in *'jq -er'*'LOAD_SHARES_BEFORE" =~ ^[0-9]+$'*'stop_load_worker'*) ;; *) exit 1 ;; esac
case "$load_src" in *'LOAD_BASELINE_NAMES="$(worker_names)"'*'LOAD_EXPECTED_WORKERS='*'wait_load_workers 180'*) ;; *) exit 1 ;; esac
case "$wait_src" in *'wait_workers "${LOAD_EXPECTED_WORKERS:-$WORKERS}"'*'worker_set_ready "$names"'*'sleep 8'*) ;; *) exit 1 ;; esac
case "$cleanup_src" in *'find /tmp'*'-uid \$(id -u)'*'stop_load_worker'*) ;; *) exit 1 ;; esac
case "$sample_src" in *'LOAD_MAX_HASHES='*'LOAD_MAX_SHARES='*'timeout 8s docker compose ps --services --status running'*'worker_set_ready "$names"'*'LOAD_SAW_RECOVERY=1'*'LOAD_SAW_FAILOVER=1'*'LOAD_METRICS_SAMPLED=1'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'LOAD_MAX_HASHES'*'LOAD_MAX_SHARES'*'[ "$LOAD_MAX_SHARES" -gt "$LOAD_SHARES_BEFORE" ]'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'sample_load_worker'*'load worker evidence:'*'process_sampled'*'multi-worker-metrics.json'*'LOAD_SAW_READY'*'LOAD_SAW_FAILOVER'*'LOAD_SAW_RECOVERY'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'clone is no longer online'*) exit 1 ;; esac
case "$verify_src" in *'LOAD_METRICS_SAMPLED" = 1'*) exit 1 ;; esac
grep -Fqx '    [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]] || latency=null' <<<"$verify_src" || exit 1
case "$stop_src" in *'pithead-e2e-load\.'*'cleanup-failed'*'/proc/[0-9]*/cmdline'*'q=\${f#/proc/}'*'kill -TERM'*'rm -rf'*) ;; *) exit 1 ;; esac
case "$restore_src" in *'stop_load_worker || RESTORE_PROOF_FAILED=1'*) ;; *) exit 1 ;; esac
case "$run_src" in *'LOAD_EXPECTED_WORKERS:-$WORKERS'*'harness_pregate "$expected_workers"'*'.e2e-run.sh'*'$expected_workers'*'deadline=$(($(date +%s) + 7200))'*'wait_load_workers 180'*load_worker_wait_tick*) ;; *) exit 1 ;; esac
case "$run_src" in *'|| die '*) exit 1 ;; esac
grep -Fqx '    verify_load_worker || hrc=1' <<<"$main_src" || exit 1
grep -Fqx '[ "$BORROW_MINER" = 1 ] || [ "$WORKERS" -ne 3 ] 2>/dev/null || die "--workers 3 requires a borrowed miner."' "$SRC" || exit 1
case "$borrow_src" in *'baseline_workers=1'*) ;; *) exit 1 ;; esac

echo "== worker_set_ready: the observed baseline plus clone, never fixed capacity (#1999) =="
# shellcheck source=tests/integration/lib/load-worker.sh
source "$LOAD_SRC"
rendered_config="$(jq --arg name clone "$LOAD_WORKER_CONFIG_FILTER" <<<'{"pools":[{"user":"real"}],"http":{"enabled":true,"host":"0.0.0.0","port":8080,"access-token":null},"autosave":true,"background":true,"log-file":"operator.log"}')"
jq -e '.pools[0].user == "clone" and .http == {"enabled":false} and .autosave == false and .background == false and (has("log-file") | not)' <<<"$rendered_config" >/dev/null || {
    echo "FAIL: clone config retained a listener, autosave/background mode, or operator log path"
    exit 1
}
STALE_STOPPED=""
on_miner() {
    case "$1" in
    *'find /tmp'*)
        case "$1" in
        *'-uid $(id -u)'*) printf '%s\n' /tmp/pithead-e2e-load.stale ;;
        *) printf '%s\n' /tmp/pithead-e2e-load.stale /tmp/pithead-e2e-load.foreign ;;
        esac
        ;;
    *) STALE_STOPPED="$LOAD_WORKER_DIR" ;;
    esac
}
quote_arg() { printf '%q' "$1"; }
cleanup_stale_load_workers
[ "$STALE_STOPPED" = /tmp/pithead-e2e-load.stale ] && [ -z "$LOAD_WORKER_DIR" ] || {
    echo "FAIL: a prior identity-bound clone was not stopped before a new launch"
    exit 1
}
WORKERS=3
LOAD_WORKER_NAME="pithead-e2e-load-clone"
LOAD_BORROWED_NAME="miner-1"
LOAD_BASELINE_NAMES="$(printf 'miner-1\nminer-2\n')"
worker_set_ready "$(printf 'miner-1\nminer-2\npithead-e2e-load-clone\n')" || {
    echo "FAIL: the two-worker baseline plus clone should be ready"
    exit 1
}
worker_set_ready "$(printf 'bench-probe\nminer-1\nminer-2\npithead-e2e-load-clone\n')" || {
    echo "FAIL: an extra worker must not block readiness"
    exit 1
}
! worker_set_ready "$(printf 'bench-ci-e2e\nminer-3\npithead-e2e-load-clone\n')" || {
    echo "FAIL: replacement workers must not satisfy a missing baseline label"
    exit 1
}
on_miner() { printf '%s\n' bench-ci-e2e; }
quote_arg() { printf '%q' "$1"; }
MINER_XMRIG_CONFIG=/tmp/config.json
refresh_load_borrowed_name
worker_set_ready "$(printf 'bench-ci-e2e\nminer-2\npithead-e2e-load-clone\n')" || {
    echo "FAIL: the refreshed borrowed label and unchanged baseline should satisfy readiness"
    exit 1
}
LOAD_BASELINE_NAMES=bench-ci-e2e
worker_set_ready "$(printf 'bench-ci-e2e\npithead-e2e-load-clone\n')" || {
    echo "FAIL: a one-rig baseline plus clone must pass despite the --workers 3 opt-in"
    exit 1
}
! worker_set_ready "$(printf 'bench-ci-e2e\nminer-3\n')" || {
    echo "FAIL: the clone itself missing must still be caught"
    exit 1
}
echo "  ✓ exact baseline plus clone passes for one or more rigs; replacement or no clone fails"

echo "== sample_load_worker: retains live evidence before harness restoration =="
on_bench() {
    case "$1" in
    *api/state*) printf '%s\n' "$SAMPLE_STATE" ;;
    *'docker compose'*) printf '%s\n' running ;;
    *) return 1 ;;
    esac
}
on_miner() { printf '%s\n' '12.5 2048'; }
quote_arg() { printf '%q' "$1"; }
E2E_DIR=/tmp/pithead-e2e
LOAD_WORKER_DIR=/tmp/pithead-e2e-load.test
LOAD_WORKER_CONFIG=$LOAD_WORKER_DIR/config.json
LOAD_MAX_HASHES=0 LOAD_MAX_SHARES=0 LOAD_MAX_CLONE_SHARES=0
LOAD_PEAK_CPU=0 LOAD_PEAK_RSS=0 LOAD_METRICS_SAMPLED=0
LOAD_SAW_READY=0 LOAD_SAW_FAILOVER=0 LOAD_SAW_RECOVERY=0
LOAD_BASELINE_NAMES="$(printf 'miner-1\nminer-2\n')"
SAMPLE_STATE='{"workers":[{"name":"miner-1","status":"online","h15":"bad","accepted":0},{"name":"miner-2","status":"online","h15":100,"accepted":0},{"name":"pithead-e2e-load-clone","status":"online","h15":100,"accepted":0}]}'
sample_load_worker
[ "$LOAD_MAX_HASHES" = 0 ] || {
    echo "FAIL: a non-numeric worker rate was omitted instead of invalidating the sample"
    exit 1
}
SAMPLE_STATE='{"workers":[{"name":"miner-1","status":"online","h15":100,"accepted":2},{"name":"miner-2","status":"online","h15":100,"accepted":1},{"name":"pithead-e2e-load-clone","status":"online","h15":100,"accepted":2}]}'
sample_load_worker
SAMPLE_STATE='{"workers":[]}'
sample_load_worker
[ "$LOAD_MAX_HASHES" = 300 ] && [ "$LOAD_MAX_SHARES" = 5 ] && [ "$LOAD_MAX_CLONE_SHARES" = 2 ] && [ "$LOAD_METRICS_SAMPLED" = 1 ] || {
    echo "FAIL: live hash/share/process evidence was not retained"
    exit 1
}
echo "  ✓ live hash/share/process evidence survives a later empty API state"
