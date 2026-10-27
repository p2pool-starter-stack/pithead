#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/../../.."
echo "== hardening onion provisioning and restoration =="
bash "$HERE/selftest-hardening-control-units.sh"
python3 "$HERE/hardening_onion.py" --selftest
python3 "$HERE/test_hardening_onion_state.py"
