#!/usr/bin/env bash
# Config-version upgrade proof, using the real assertion helper without a server.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/live-gates.sh
source "$HERE/lib/live-gates.sh"
# shellcheck disable=SC2034 # read by the sourced assertion helper
UPGRADE_CANDIDATE_DIR=/candidate
echo "== unit: configuration version upgrade proof =="
rx() {
    case "$1" in
    *jq*) printf '%s' "$TEST_STAMP" ;;
    *VERSION*) printf '%s' "$TEST_CODE_VERSION" ;;
    *docker\ exec*) printf '%s' "$TEST_AUDIT" ;;
    *) return 1 ;;
    esac
}
for TEST_CODE_VERSION in 2.0.0-pre.1+build bad ''; do
    for TEST_STAMP in 2.0.0 9.9.9 ''; do
        for TEST_AUDIT in clean stamp-recorded '' bad; do
            IT_FAIL=0
            assert_upgrade_config_version >/dev/null 2>&1
            expected=0
            { [ "$TEST_STAMP" = 2.0.0 ] && [ "$TEST_CODE_VERSION" = 2.0.0-pre.1+build ]; } || expected=$((expected + 1))
            [ "$TEST_AUDIT" = clean ] || expected=$((expected + 1))
            [ "$IT_FAIL" = "$expected" ] || {
                printf 'FAIL: upgrade config assertions failed to detect fixture\n'
                exit 1
            }
        done
    done
done
printf 'PASS: upgrade stamp and audit assertions detect missing, malformed and stamp-bearing evidence\n'
python3 - "$HERE/lib/config-version-audit.py" <<'PY'
import runpy
import sqlite3
import sys
probe = runpy.run_path(sys.argv[1])["stamp_recorded"]
with sqlite3.connect(":memory:") as conn:
    try:
        probe(conn)
    except sqlite3.OperationalError:
        pass
    else:
        raise AssertionError("missing audit table passed")
    conn.execute("CREATE TABLE audit_events (keys TEXT)")
    conn.execute("INSERT INTO audit_events VALUES ('p2pool.pool')")
    assert not probe(conn)
    for key in ("config_version", "config_version.x"):
        conn.execute("INSERT INTO audit_events VALUES (?)", (key,))
        assert probe(conn)
        conn.execute("DELETE FROM audit_events WHERE keys=?", (key,))
print("PASS: durable audit proof accepts real setting rows and refuses stamp paths")
PY
