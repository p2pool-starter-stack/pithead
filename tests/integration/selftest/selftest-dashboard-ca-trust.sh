#!/usr/bin/env bash
set -euo pipefail
echo "== DIY dashboard CA export and recovery checks =="
python3 "${BASH_SOURCE[0]%/*}/selftest_dashboard_ca_trust.py"
