#!/usr/bin/env bash
# The tier-4 load worker is opt-in and must remain one-threaded, baseline-relative,
# and cleanup-safe. This source-level contract is the cheap guard; the live leg proves XMRig.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../e2e.sh"
LOAD_SRC="$HERE/../lib/load-worker.sh"
worker_src="$(sed -n '/^worker_names() {$/,/^}$/p' "$LOAD_SRC")"
load_src="$(sed -n '/^start_load_worker() {$/,/^}$/p' "$LOAD_SRC")"
verify_src="$(sed -n '/^verify_load_worker() {$/,/^}$/p' "$LOAD_SRC")"
stop_src="$(sed -n '/^stop_load_worker() {$/,/^}$/p' "$LOAD_SRC")"
sample_src="$(sed -n '/^sample_load_worker() {$/,/^}$/p' "$LOAD_SRC")"
restore_src="$(sed -n '/^restore_all() {$/,/^}$/p' "$SRC")"
borrow_src="$(sed -n '/^borrow_miner() {$/,/^}$/p' "$SRC")"
run_src="$(sed -n '/^run_harness() {$/,/^}$/p' "$SRC")"
main_src="$(sed -n '/^main() {$/,/^}$/p' "$SRC")"

echo "== selftest: load worker stays opt-in, capped, baseline-relative, and cleanup-safe =="
case "$worker_src" in *'select(.status == \"online\")'*) ;; *) exit 1 ;; esac
case "$load_src" in *'[ "$WORKERS" -ge 3 ]'*) ;; *) exit 1 ;; esac
case "$load_src" in *'--threads=1'*) ;; *) exit 1 ;; esac
case "$load_src" in *'LOAD_BASELINE_COUNT + 1'*) ;; *) exit 1 ;; esac
case "$load_src" in *'umask 077'*'mktemp -d'*) ;; *) exit 1 ;; esac
case "$load_src" in *'-eq $((LOAD_BASELINE_COUNT + 1))'*) ;; *) exit 1 ;; esac
case "$load_src" in *'owned()'*'cleanup-failed'*'kill -KILL'*'trap fail EXIT'*) ;; *) exit 1 ;; esac
case "$load_src" in *'jq -er'*'LOAD_SHARES_BEFORE" =~ ^[0-9]+$'*'stop_load_worker'*) ;; *) exit 1 ;; esac
case "$sample_src" in *'docker compose ps --services --status running'*'LOAD_SAW_RECOVERY=1'*'LOAD_SAW_FAILOVER=1'*'LOAD_METRICS_SAMPLED=1'*'LOAD_PEAK_CPU='*'LOAD_PEAK_RSS='*) ;; *) exit 1 ;; esac
case "$verify_src" in *'[ "$names" = "$expected" ]'*'all('*'. >= 0'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'.accepted | tonumber?'*'quote_arg "$clone_shares"'*'[ "$clone_shares" -gt 0 ]'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'sample_load_worker'*'load worker evidence:'*'process_sampled'*'multi-worker-metrics.json'*'[ "$names" = "$expected" ]'*'LOAD_SAW_READY'*'LOAD_SAW_FAILOVER'*'LOAD_SAW_RECOVERY'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'LOAD_METRICS_SAMPLED" = 1'*) exit 1 ;; esac
grep -Fqx '    [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]] || latency=null' <<<"$verify_src" || exit 1
case "$stop_src" in *'pithead-e2e-load\.'*'cleanup-failed'*'/proc/'*'kill -TERM'*'rm -rf'*) ;; *) exit 1 ;; esac
case "$restore_src" in *'stop_load_worker || RESTORE_PROOF_FAILED=1'*) ;; *) exit 1 ;; esac
case "$run_src" in *load_worker_wait_tick*) ;; *) exit 1 ;; esac
grep -Fqx '    verify_load_worker || hrc=1' <<<"$main_src" || exit 1
case "$borrow_src" in *'baseline_workers=1'*) ;; *) exit 1 ;; esac
