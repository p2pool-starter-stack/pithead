#!/usr/bin/env bash
# CI-only real libcurl wire contract against a bounded, local synthetic HTTP server.
set -euo pipefail
echo "== libcurl connection-bound restoration Digest =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/test_restore_curl_connection.py"
