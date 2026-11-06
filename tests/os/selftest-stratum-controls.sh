#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../integration/scenarios.sh"
overrides=$(scenario_overrides remote-main-stratum-tls)
[[ "$overrides" == *"monero.mode=remote"* && "$overrides" == *"p2pool.stratum_tls=true"* && "$overrides" == *"p2pool.stratum_password=auto"* ]] || exit 1
python3 "$HERE/../integration/selftest/test_rotate_auth_probe.py" StratumMinerTest StratumSuiteTest

bash "$HERE/../integration/selftest/selftest-scenario-stratum.sh"
