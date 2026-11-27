#!/usr/bin/env bash
# Diagnose a second mining-service hold without changing the latch, marker or service state.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=tests/integration/lib/run-source-image.sh
source "$ROOT/tests/integration/lib/run-source-image.sh"
echo "== lifecycle sync-gate diagnostic transitions and redaction =="
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/data"
export GATE_FIXTURE="$fixture"
cat >"$fixture/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
'compose exec -T dashboard python3 -c '*)
    [ "${GATE_FAIL:-0}" != 1 ] || exit 1
    if [ "${GATE_HANG:-0}" = 1 ]; then
        exec "$REAL_PYTHON" -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(600)'
    fi
    python3 -c "${*: -1}" ;;
'compose ps --services --status running')
    [ "${GATE_FAIL:-0}" != 1 ] || exit 1
    cat "$GATE_FIXTURE/running" ;;
*) exit 1 ;;
esac
DOCKER
# Redirect only the fake container's fixed data mount, keeping the real read-only Python query.
cat >"$fixture/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
exec "$REAL_PYTHON" -c "${2//\/data/$GATE_FIXTURE/data}"
PYTHON
chmod +x "$fixture/bin/"*
export REAL_PYTHON
REAL_PYTHON=$(command -v python3)
# Include deliberately sensitive unrelated values. None may leave the query.
python3 - "$fixture/data/mining_data.db" <<'PY'
import json, sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('CREATE TABLE kv_store (key TEXT PRIMARY KEY, value TEXT)')
    db.execute('INSERT INTO kv_store VALUES (?, ?)', ('snapshot_latest_data', json.dumps({'miner_released': True, 'secret': 'fixture-private-credential'})))
PY
printf 'p2pool\nxmrig-proxy\n' >"$fixture/running"
probe=$(lifecycle_gate_snippet)
sample() { PATH="$fixture/bin:$PATH" bash -c "$probe
lifecycle_gate_sample_target $1"; }
before=$(sha256sum "$fixture/data/mining_data.db")
out=$(sample before-restart)
[ "$out" = 'lifecycle-gate: before-restart marker=absent snapshot_release=true p2pool=running proxy=running' ]
[ "$(sha256sum "$fixture/data/mining_data.db")" = "$before" ]
# Persisted unreleased state and an explicit marker are independently reported after a restart.
python3 - "$fixture/data/mining_data.db" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('UPDATE kv_store SET value = ?', ('{"miner_released":false}',))
PY
touch "$fixture/data/sync-gate-reset"
printf 'dashboard\n' >"$fixture/running"
before=$(sha256sum "$fixture/data/mining_data.db")
out=$(sample after-up)
[ "$out" = 'lifecycle-gate: after-up marker=present snapshot_release=false p2pool=stopped proxy=stopped' ]
[ -f "$fixture/data/sync-gate-reset" ]
[ "$(sha256sum "$fixture/data/mining_data.db")" = "$before" ]
# Unavailable reads remain explicit; they never masquerade as a released or absent latch.
export GATE_FAIL=1
out=$(sample before-source-image)
[ "$out" = 'lifecycle-gate: before-source-image marker=unknown snapshot_release=unavailable p2pool=unknown proxy=unknown' ]
unset GATE_FAIL
rm "$fixture/data/mining_data.db"
out=$(sample before-source-image)
[[ "$out" == *'snapshot_release=unavailable'* ]]
[ ! -e "$fixture/data/mining_data.db" ]
# Retention discards raw command errors, credentials and malformed or injected records.
retained=$(printf '%s\n' "$out" 'fixture-private-credential' \
    'lifecycle-gate: injected marker=present snapshot_release=true p2pool=running proxy=running' \
    'lifecycle-gate: after-up marker=absent snapshot_release=fixture-private-credential p2pool=running proxy=running' | retain_lifecycle_gate_samples)
[ "$retained" = "$out" ]
# Exercise the outer sampler's explicit transport-failure record and artifact retention.
OUT_DIR=$fixture
rx() { return 1; }
quote_arg() { printf "'%s'" "$1"; }
lifecycle_gate_sample after-restart
grep -Fxq 'lifecycle-gate: after-restart marker=unknown snapshot_release=unavailable p2pool=unknown proxy=unknown' "$fixture/lifecycle-gate.log"
rx() { printf '%s\n' 'untrusted noise'; }
lifecycle_gate_sample before-restart
grep -Fxq 'lifecycle-gate: before-restart marker=unknown snapshot_release=unavailable p2pool=unknown proxy=unknown' "$fixture/lifecycle-gate.log"
# The actual production timeout must forcibly end a client that ignores TERM.
start=$SECONDS
out=$(GATE_HANG=1 sample before-source-image)
[ "$((SECONDS - start))" -lt 16 ]
[[ "$out" == *'marker=unknown snapshot_release=unavailable'* ]]
echo 'selftest-lifecycle-gate: transition, read-only query, unavailable reads and safe retention passed'
