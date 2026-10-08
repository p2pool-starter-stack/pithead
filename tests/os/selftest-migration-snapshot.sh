#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?set TMPDIR or RUNNER_TEMP}}"
HERE=$(cd "$(dirname "$0")" && pwd)
python3 - "$HERE/migration-release-snapshot.py" <<'PY'
import json
import os
import sqlite3
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as directory:
    path = os.path.join(directory, "snapshot.db")
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE kv_store (key TEXT PRIMARY KEY, value TEXT)")
        db.execute("INSERT INTO kv_store VALUES (?, ?)", (
            "snapshot_latest_data", json.dumps({"miner_released": True, "other": 123})
        ))
    result = subprocess.run([sys.executable, sys.argv[1], path], capture_output=True, text=True)
    if result.returncode != 0 or result.stdout.strip() != "persisted mining release verified":
        raise SystemExit("FAIL: reading the earned release failed")
    with sqlite3.connect(path) as db:
        snapshot = json.loads(db.execute("SELECT value FROM kv_store").fetchone()[0])
        if snapshot != {"miner_released": True, "other": 123}:
            raise SystemExit("FAIL: verifying release changed a snapshot field")
        db.execute("UPDATE kv_store SET value = ?", (json.dumps({"miner_released": False}),))
    result = subprocess.run([sys.executable, sys.argv[1], path], capture_output=True)
    if result.returncode == 0:
        raise SystemExit("FAIL: an unearned release satisfied the precondition")
    with sqlite3.connect(path) as db:
        db.execute("DELETE FROM kv_store")
    result = subprocess.run([sys.executable, sys.argv[1], path], capture_output=True)
    if result.returncode == 0:
        raise SystemExit("FAIL: a fresh database satisfied the carried-release precondition")
print("selftest-migration-snapshot: PASS")
PY

# A later same-version health-fault build must not overwrite the good recovery input.
# shellcheck source=tests/os/migration-same-version-fallback.sh
source "$HERE/migration-same-version-fallback.sh"
T=$(mktemp -d "${TMPDIR:?}/migration-bundles.XXXXXX")
trap 'rm -rf "$T"; [ -z "${saved:-}" ] || rm -f "$saved"' EXIT
printf 'good bundle\n' >"$T/update.raucb"
saved=$(preserve_migration_bundle "$T/update.raucb")
printf 'fault bundle\n' >"$T/update.raucb"
[ "$(cat "$saved")" = 'good bundle' ] || {
    echo 'FAIL: fault build destroyed the good bundle'
    exit 1
}
echo 'selftest-migration-bundle-preservation: PASS'
