#!/usr/bin/env bash
# Supersession proof and refusals run without a live wallet or Docker.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/test-wallet-supersession.py"
