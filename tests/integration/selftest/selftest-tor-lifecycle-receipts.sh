#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals are read by the sourced harness.
set -euo pipefail
echo "== Tor lifecycle receipt capture and bounds =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
INTEGRATION_RUN_SUITE=1
source "$HERE/lib/tor-lifecycle-receipts.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
IT_MODE=local IT_REMOTE_DIR="$work" OUT_DIR="$work/results"
mkdir -p "$work/tests/integration/tools"
cp "$HERE/tools/tor-lifecycle-receipts.py" "$work/tests/integration/tools/"
cat >"$work/fake-cli" <<'SH'
#!/usr/bin/env bash
echo private-onion-key
echo private-engine-error >&2
printf '%s\n' 'pithead-tor-lifecycle {"timestamp":"2026-01-01T00:00:00Z","caller":"onion-rotation","operation":"rotate-1-2","container":"unavailable","action":"stop","result":"9"}' >&2
exit 7
SH
chmod +x "$work/fake-cli"
IT_PITHEAD=./fake-cli
rc=0
rotation_with_receipts || rc=$?
assert_rc "capture preserves the lifecycle command's failure" "$rc" 7
assert_eq "only the structured receipt is retained" "$(wc -l <"$OUT_DIR/tor-lifecycle/rotation.jsonl" | tr -d ' ')" 1
if [[ "$(cat "$OUT_DIR/tor-lifecycle/rotation.jsonl")" = *private* ]]; then
    private_found=1
else
    private_found=0
fi
assert_eq "raw credentials cannot reach the receipt artifact" "$private_found" 0
OUT_DIR="$work/not-a-directory"
touch "$OUT_DIR"
it_fail() { :; }
rc=0
rotation_with_receipts 2>/dev/null || rc=$?
assert_rc "artifact write failure cannot change the lifecycle result" "$rc" 7
python3 - "$HERE/tools/tor-lifecycle-receipts.py" <<'PY'
import importlib.util
import json
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('receipts', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
row = dict(timestamp='2026-01-01T00:00:00Z', caller='tor-heal', operation='a'*32,
           container='b'*64, action='start', result='unconfirmed')
line = module.PREFIX + json.dumps(row) + '\n'
assert module.project(line) == row
for field in row:
    bad = dict(row, **{field: 'private.onion key=value'})
    assert module.project(module.PREFIX + json.dumps(bad)) is None
assert module.project(module.PREFIX + json.dumps(dict(row, extra='private'))) is None
payload = ('x'*5000 + '\n' + line*200).encode()
result = subprocess.run([sys.executable, sys.argv[1], 'collect'], input=payload, capture_output=True, check=True)
assert len(result.stdout.splitlines()) == 128
assert all(json.loads(line) == row for line in result.stdout.splitlines())
with tempfile.NamedTemporaryFile(mode='w+', dir=None) as artifact:
    json.dump(dict(row, operation='unavailable'), artifact)
    artifact.flush()
    try:
        module.verify([artifact.name])
    except ValueError as error:
        assert 'operation identity' in str(error)
    else:
        raise AssertionError('missing operation identity passed verification')
PY
echo 'Tor receipt capture and bounds PASS'
[ "$IT_FAIL" -eq 0 ]
