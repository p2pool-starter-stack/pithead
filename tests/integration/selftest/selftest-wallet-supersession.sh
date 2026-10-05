#!/usr/bin/env bash
# Supersession proof and refusals run without a live wallet or Docker.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "== wallet supersession: identity proof, refusals and retained evidence =="
python3 "$HERE/test-wallet-supersession.py"
python3 "$HERE/test-wallet-supersession-proof.py"
