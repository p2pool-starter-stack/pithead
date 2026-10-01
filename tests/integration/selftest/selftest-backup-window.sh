#!/usr/bin/env bash
# Versioned backup-window fixtures are stdlib-only, also run in the shell CI gate.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -m unittest discover -s "$HERE" -p "test_backup_window*.py"
