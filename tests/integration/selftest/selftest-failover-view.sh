#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
# shellcheck source=tests/integration/lib.sh
source "$ROOT/lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-failover-view.sh
source "$ROOT/lib/run-failover-view.sh"
echo "== failover view: aggregates, banner, fake stratum and pool reorder =="
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
check() { # <desc> <expected-rc> <command...>
    local desc="$1" want="$2" rc
    shift 2
    "$@" >/dev/null 2>&1
    rc=$?
    { [ "$rc" = "$want" ] || { [ "$want" = 1 ] && [ "$rc" != 0 ]; }; } || {
        echo "FAIL: $desc (rc=$rc, want $want)" >&2
        fail=1
    }
}

row() { # <name> <status> <state> <h15> <h60> <telemetry>
    jq -cn --arg n "$1" --arg s "$2" --arg m "$3" --argjson h15 "$4" --argjson h60 "$5" --argjson t "$6" \
        '{name:$n,status:$s,mining:{state:$m,pool:"pool.example:3399"},h15:$h15,h60:$h60,telemetry_h60:$t}'
}
state() { # <alive> <total> <badge-or-empty> <rows...>
    local alive="$1" total="$2" badge="$3"
    shift 3
    jq -cn --argjson alive "$alive" --arg total "$total" --arg badge "$badge" --slurpfile rows <(printf '%s\n' "$@") \
        '{proxy_workers:$alive,hashrate:{total:$total},workers:$rows,badges:(if $badge == "" then [] else [{text:$badge,variant:"bad"}] end)}'
}

here="$(state 2 "3.00 kH/s" "" "$(row rig1 online mining_here 1000 900 1200)" "$(row rig2 online mining_here 2000 1900 2100)")"
moved="$(state 1 "2.00 kH/s" "" "$(row rig1 online on_backup 0 0 1200)" "$(row rig2 online mining_here 2000 1900 2100)")"
blended="$(state 2 "3.20 kH/s" "" "$(row rig1 online on_backup 0 0 1200)" "$(row rig2 online mining_here 2000 1900 2100)")"
alive_blended="$(state 2 "2.00 kH/s" "" "$(row rig1 online on_backup 0 0 1200)" "$(row rig2 online mining_here 2000 1900 2100)")"
fallback="$(state 1 "900.00 H/s" "" "$(row rig1 online mining_here 0 900 1200)")"
paused_one="$(state 1 "2.00 kH/s" "Mining paused here: stratum closed, 1 rig on backup pool" "$(row rig1 online on_backup 0 0 1200)" "$(row rig2 online mining_here 2000 1900 2100)")"
paused_wrong="$(state 1 "2.00 kH/s" "Mining paused here: stratum closed, 2 rigs on backup pool" "$(row rig1 online on_backup 0 0 1200)")"
paused_bare="$(state 1 "2.00 kH/s" "Mining paused here: stratum closed" "$(row rig1 online on_backup 0 0 1200)")"
paused_two="$(state 0 "0.00 H/s" "Mining paused here: node out of sync, 2 rigs on backup pool" "$(row rig1 offline on_backup 0 0 1200)" "$(row rig2 online on_backup 0 0 1)")"

check "healthy both-here aggregates agree" 0 _failover_aggregates_json "$here"
check "a moved rig drops out of both aggregates" 0 _failover_aggregates_json "$moved"
check "telemetry blended into Total Hashrate is refused" 1 _failover_aggregates_json "$blended"
check "a moved rig still counted in Workers Alive is refused" 1 _failover_aggregates_json "$alive_blended"
check "the 1m fallback is what the total uses" 0 _failover_aggregates_json "$fallback"
check "malformed totals are refused" 1 _failover_aggregates_json '{"proxy_workers":1,"hashrate":{"total":"n/a"},"workers":[]}'
check "banner names one rig singular" 0 _failover_banner_matches "$paused_one"
check "banner with the wrong rig count is refused" 1 _failover_banner_matches "$paused_wrong"
check "banner without the rig count is refused" 1 _failover_banner_matches "$paused_bare"
check "banner names two rigs plural" 0 _failover_banner_matches "$paused_two"
check "no banner and no rig on a backup pool is refused" 1 _failover_banner_matches "$here"
[ "$(_failover_row_field "$moved" rig1 '.mining.state')" = on_backup ] || {
    echo "FAIL: row field lookup" >&2
    fail=1
}
[ -z "$(_failover_row_field "$moved" absent '.mining.state')" ] || {
    echo "FAIL: absent row must read empty" >&2
    fail=1
}

[ "$FAILOVER_POOL_PORT" = "$(sed -n 's/^FAILOVER_POOL_PORT=//p' "$ROOT/lib/borrow-fixture.sh")" ] || {
    echo "FAIL: controller and bench disagree on the second pool port" >&2
    fail=1
}

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 "$ROOT/fakes/fake_stratum.py" 127.0.0.1 "$port" "$WORK/log" &
pool=$!
for _ in $(seq 1 50); do
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null && break
    sleep 0.1
done
reply="$(
    python3 - "$port" <<'PY'
import json
import socket
import sys

conn = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 5)
f = conn.makefile("rw")
f.write(json.dumps({"id": 1, "method": "login", "params": {"login": "x", "pass": "x"}}) + "\n")
f.flush()
login = json.loads(f.readline())
job = login["result"]["job"]
assert login["result"]["status"] == "OK" and len(job["blob"]) >= 152 and len(job["target"]) == 8
f.write(json.dumps({"id": 2, "method": "submit", "params": {"id": "x", "job_id": job["job_id"]}}) + "\n")
f.flush()
assert json.loads(f.readline())["result"]["status"] == "OK"
print("served")
PY
)"
kill "$pool" 2>/dev/null
wait "$pool" 2>/dev/null
[ "$reply" = served ] || {
    echo "FAIL: fake stratum did not serve a login and a submit" >&2
    fail=1
}
[ "$(grep -c '^login$' "$WORK/log")" = 1 ] || {
    echo "FAIL: fake stratum did not record the login" >&2
    fail=1
}

printf '{"pools":[{"url":"bench.example:3333","user":"w"},{"url":"other.example:3333","user":"w"}]}' >"$WORK/xmrig.json"
BENCH_HOST=bench.example
MINER_XMRIG_CONFIG="$WORK/xmrig.json"
# shellcheck source=tests/integration/lib/borrow-fixture.sh
source "$ROOT/lib/borrow-fixture.sh"
on_miner() { bash -c "$1"; }
miner_reload() { :; }
step() { :; }
wait_for() { :; }
failover_miner_pool 3399 || {
    echo "FAIL: failover_miner_pool" >&2
    fail=1
}
[ "$(jq -r '.pools | map(.url) | join(",")' "$WORK/xmrig.json")" = "bench.example:3399,bench.example:3333,other.example:3333" ] || {
    echo "FAIL: the second pool must lead and the stack pool stay second" >&2
    fail=1
}
repoint_miner || {
    echo "FAIL: repoint_miner" >&2
    fail=1
}
[ "$(jq -r '.pools | map(.url) | join(",")' "$WORK/xmrig.json")" = "bench.example:3333,other.example:3333" ] || {
    echo "FAIL: the rearm must drop the failover pool and lead with the stack pool" >&2
    fail=1
}

[ "$fail" = 0 ] && echo "selftest-failover-view: ok"
exit "$fail"
