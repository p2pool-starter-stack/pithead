#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
grep -Fq 'phase_provision_power_regressions' "$HERE/provision-browser-submit.sh"
grep -Fq '. "$SCRIPT_DIR/appliance-power-leg.sh"' "$HERE/run.sh"
bash "$HERE/appliance-power-leg.sh" --self-test
