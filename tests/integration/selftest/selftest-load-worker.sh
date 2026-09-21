#!/usr/bin/env bash
# The tier-4 load worker is opt-in and must remain one-threaded, baseline-relative,
# and cleanup-safe. This source-level contract is the cheap guard; the live leg proves XMRig.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../e2e.sh"
LOAD_SRC="$HERE/../lib/load-worker.sh"
worker_src="$(sed -n '/^worker_names() {$/,/^}$/p' "$LOAD_SRC")"
borrowed_src="$(sed -n '/^refresh_load_borrowed_name() {$/,/^}$/p' "$LOAD_SRC")"
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
case "$load_src" in *'owned()'*'cleanup-failed'*'kill -KILL'*'trap fail EXIT'*) ;; *) exit 1 ;; esac
case "$load_src" in *'test -z'*'wait'*'rm -rf --'*) ;; *) exit 1 ;; esac
case "$load_src" in *'jq -er'*'LOAD_SHARES_BEFORE" =~ ^[0-9]+$'*'stop_load_worker'*) ;; *) exit 1 ;; esac
case "$sample_src" in *'docker compose ps --services --status running'*'worker_set_ready "$names"'*'LOAD_SAW_RECOVERY=1'*'LOAD_SAW_FAILOVER=1'*'LOAD_METRICS_SAMPLED=1'*'LOAD_PEAK_CPU='*'LOAD_PEAK_RSS='*) ;; *) exit 1 ;; esac
case "$verify_src" in *'grep -Fxq -- "$LOAD_WORKER_NAME"'*'all('*'isfinite'*'. >= 0'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'.accepted | tonumber?'*'quote_arg "$clone_shares"'*'[ "$shares" -gt "$LOAD_SHARES_BEFORE" ]'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'sample_load_worker'*'load worker evidence:'*'process_sampled'*'multi-worker-metrics.json'*'LOAD_SAW_READY'*'LOAD_SAW_FAILOVER'*'LOAD_SAW_RECOVERY'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'all($r[]; isfinite and . >= 0)'*'isfinite and . > 0'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'LOAD_METRICS_SAMPLED" = 1'*) exit 1 ;; esac
grep -Fqx '    [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]] || latency=null' <<<"$verify_src" || exit 1
case "$stop_src" in *'pithead-e2e-load\.'*'cleanup-failed'*'/proc/'*'kill -TERM'*'rm -rf'*) ;; *) exit 1 ;; esac
case "$restore_src" in *'stop_load_worker || RESTORE_PROOF_FAILED=1'*) ;; *) exit 1 ;; esac
case "$run_src" in *'refresh_load_borrowed_name'*load_worker_wait_tick*) ;; *) exit 1 ;; esac
case "$run_src" in *'|| die '*) exit 1 ;; esac
grep -Fqx '    verify_load_worker || hrc=1' <<<"$main_src" || exit 1
grep -Fqx '[ "$BORROW_MINER" = 1 ] || [ "$WORKERS" -ne 3 ] 2>/dev/null || die "--workers 3 requires a borrowed miner."' "$SRC" || exit 1
case "$borrow_src" in *'baseline_workers=1'*) ;; *) exit 1 ;; esac

echo "== worker_set_ready: requested capacity + clone, independent of transient labels (#1999) =="
# shellcheck source=tests/integration/lib/load-worker.sh
source "$LOAD_SRC"
WORKERS=3
LOAD_WORKER_NAME="pithead-e2e-load-clone"
LOAD_BORROWED_NAME="miner-1"
worker_set_ready "$(printf 'miner-1\nminer-2\npithead-e2e-load-clone\n')" || {
    echo "FAIL: three distinct workers including the clone should be ready"
    exit 1
}
worker_set_ready "$(printf 'bench-probe\nminer-1\nminer-2\npithead-e2e-load-clone\n')" || {
    echo "FAIL: an extra worker must not block readiness"
    exit 1
}
! worker_set_ready "$(printf 'bench-ci-e2e\nminer-3\npithead-e2e-load-clone\n')" || {
    echo "FAIL: a rearmed label must be refreshed before it can satisfy readiness"
    exit 1
}
LOAD_BORROWED_NAME="bench-ci-e2e"
worker_set_ready "$(printf 'bench-ci-e2e\nminer-3\npithead-e2e-load-clone\n')" || {
    echo "FAIL: the refreshed borrowed-worker label should satisfy readiness"
    exit 1
}
! worker_set_ready "$(printf 'miner-1\nminer-2\npithead-e2e-load-clone\n' | head -n 2)" || {
    echo "FAIL: fewer than the requested workers must fail"
    exit 1
}
! worker_set_ready "$(printf 'miner-1\nminer-2\nminer-3\n')" || {
    echo "FAIL: the clone itself missing must still be caught"
    exit 1
}
echo "  ✓ capacity plus clone and the refreshed borrowed label passes; replacement, too few workers, or no clone fails"
