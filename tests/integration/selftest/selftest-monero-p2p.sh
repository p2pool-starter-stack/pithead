#!/usr/bin/env bash
# Pure wire fixtures: no network or daemon.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "== Monero P2P advertisement decoder =="
python3 "$HERE/test_monero_p2p.py"
