#!/usr/bin/env bash
# The live probe must reject old behavior, skipped checks and invalid JSON.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:?}/doctor-tip-selftest.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
cat >"$scratch/doctor" <<'CLI'
#!/usr/bin/env bash
if [ "${CASE:-}" != skipped ]; then
    curl -d '{"method":"get_last_block_header"}' > /dev/null
fi
message='monerod peers: 8 out / 2 in.'
status=ok
if [ "${CASE:-}" = old ]; then
    message='monerod peers: 8 out / 2 in, last block 1791442697s ago'
    status=warn
fi
if [ "${CASE:-}" = peerless ]; then status=warn; fi
if [ "${2:-}" = --json ]; then
    if [ "${CASE:-}" = invalid ]; then echo invalid; exit 0; fi
    jq -nc --arg message "$message" --arg status "$status" '{checks:[{status:$status,message:$message}]}'
else
    printf '%s %s\n' "${status^^}" "$message"
fi
# Unrelated checks can fail without invalidating the scoped tip proof.
exit 1
CLI
chmod +x "$scratch/doctor"
for case_name in valid old skipped invalid peerless; do
    rc=0
    CASE=$case_name bash "$ROOT/tests/integration/tools/doctor-tip-time.sh" "$scratch/doctor" >"$scratch/log" 2>&1 || rc=$?
    if [ "$case_name" = valid ]; then
        [ "$rc" = 0 ]
        grep -Fq 'text zero timestamp has no age or stale warning' "$scratch/log"
        grep -Fq 'json zero timestamp has no age or stale warning' "$scratch/log"
    else
        [ "$rc" != 0 ]
    fi
    printf 'PASS doctor tip probe: %s\n' "$case_name"
done
