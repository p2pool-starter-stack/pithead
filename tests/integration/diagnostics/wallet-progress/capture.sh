#!/usr/bin/env bash
set -uo pipefail
mkdir -p results
timeout 5 docker logs wallet-rpc 2>&1 |
    grep -E '^wallet_numeric_progress kind=[0-4] count=[0-9]+$' >results/wallet-numeric-progress.txt
rc=$?
printf 'wallet_numeric_capture_exit=%s\n' "$rc" | tee results/wallet-numeric-capture.txt
test "$rc" = 0 && test -s results/wallet-numeric-progress.txt
