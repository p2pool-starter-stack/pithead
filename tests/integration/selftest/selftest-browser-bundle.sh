#!/usr/bin/env bash
set -euo pipefail
echo "== browser support bundle probe negative controls =="
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 "$ROOT/tests/integration/tools/browser-bundle.py" --self-test
