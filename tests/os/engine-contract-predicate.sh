#!/usr/bin/env bash
set -euo pipefail
cd /data/pithead
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/readiness-churn.sh"
source "$here/status-predicate.sh"
rx() { timeout 10 bash -c "$1"; }
quote_arg() { printf '%q' "$1"; }
pithead() { timeout 20 ./pithead "$@"; }
_pred_status_ok || true
sleep 1
_pred_status_ok
