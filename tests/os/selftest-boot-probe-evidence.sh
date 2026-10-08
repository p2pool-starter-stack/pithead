#!/usr/bin/env bash
# The KVM boot-probe verdict rejects absent, stale, leaked and miscounted evidence.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/boot-probe-evidence.py" --self-test
