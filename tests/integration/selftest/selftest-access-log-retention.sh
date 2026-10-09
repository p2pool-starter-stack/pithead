#!/usr/bin/env bash
set -euo pipefail
echo "== live access-log retention failure controls =="
python3 "${BASH_SOURCE[0]%/*}/selftest_access_log_retention.py"
