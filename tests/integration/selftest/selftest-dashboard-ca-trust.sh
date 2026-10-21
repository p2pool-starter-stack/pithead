#!/usr/bin/env bash
set -euo pipefail
python3 "${BASH_SOURCE[0]%/*}/selftest_dashboard_ca_trust.py"
