#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "== backup ownership probe decryption and restoration contracts =="
python3 "$HERE/test_backup_ownership_probe.py"
