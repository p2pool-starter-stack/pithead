#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "== versioned backup-window result and boundary fixtures =="
python3 -m unittest discover -s "$HERE" -p "test_backup_window*.py"
