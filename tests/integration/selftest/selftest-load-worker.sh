#!/usr/bin/env bash
# The tier-4 load worker is opt-in and must remain one-threaded, baseline-relative,
# and cleanup-safe. This source-level contract is the cheap guard; the live leg proves XMRig.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../e2e.sh"
LOAD_SRC="$HERE/../lib/load-worker.sh"
load_src="$(sed -n '/^start_load_worker() {$/,/^}$/p' "$LOAD_SRC")"
verify_src="$(sed -n '/^verify_load_worker() {$/,/^}$/p' "$LOAD_SRC")"
restore_src="$(sed -n '/^restore_all() {$/,/^}$/p' "$SRC")"
borrow_src="$(sed -n '/^borrow_miner() {$/,/^}$/p' "$SRC")"

echo "== selftest: load worker stays opt-in, capped, baseline-relative, and cleanup-safe =="
case "$load_src" in *'[ "$WORKERS" -ge 3 ]'*) ;; *) exit 1 ;; esac
case "$load_src" in *'--threads=1'*) ;; *) exit 1 ;; esac
case "$load_src" in *'LOAD_BASELINE_COUNT + 1'*) ;; *) exit 1 ;; esac
case "$verify_src" in *'LOAD_BASELINE_NAMES'*'LOAD_WORKER_NAME'*) ;; *) exit 1 ;; esac
case "$restore_src" in *stop_load_worker*) ;; *) exit 1 ;; esac
case "$borrow_src" in *'baseline_workers=1'*) ;; *) exit 1 ;; esac
