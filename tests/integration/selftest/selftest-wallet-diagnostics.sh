#!/usr/bin/env bash
# Retain earlier OOMs even when current State has been cleared by an automatic restart.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-tari-wallet.sh"
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/bin" "$TD/wallet" "$TD/cgroup/memory"
export WALLET_TEST_CGROUP="$TD/cgroup" WALLET_TEST_PROC_STATUS="$TD/process-status"
export WALLET_TEST_PROC_IO="$TD/process-io" WALLET_TEST_PROC_STAT="$TD/process-stat"
export WALLET_TEST_PROC_WCHAN="$TD/process-wchan" WALLET_DIR="$TD/wallet"
printf 'rchar: 2000000000\nread_bytes: 400000000\nwchar: 8000\nwrite_bytes: 4096\n' >"$TD/process-io"
# A comm with spaces and parentheses must not shift the CPU/starttime fields.
printf '1 (wallet (fixture)) R 0 0 0 0 0 0 0 0 0 0 12345 678 0 0 0 0 0 0 98765\n' >"$TD/process-stat"
printf '0\n' >"$TD/process-wchan"
printf 'cache-fixture' >"$TD/wallet/payout-wallet"
printf 'keys-fixture' >"$TD/wallet/payout-wallet.keys"
printf '1800000000\n' >"$TD/cgroup/memory.current"
printf '2147483648\n' >"$TD/cgroup/memory.peak"
printf '2147483648\n' >"$TD/cgroup/memory.max"
printf 'oom_kill 1\n' >"$TD/cgroup/memory.events"
printf 'VmRSS: 1750000 kB\nVmHWM: 1800000 kB\nThreads: 32\n' >"$TD/process-status"
export WALLET_TEST_COMMANDS="$TD/commands" WALLET_TEST_LOG="$TD/wallet.log"
cat >"$WALLET_TEST_LOG" <<'EOF'
2026-10-01T01:00:00Z Opening existing view-only payout wallet
2026-10-01T01:00:01Z W Loading wallet...
2026-10-01T01:00:02Z W Loaded wallet keys file, with public address: fixture-address
2026-10-01T01:00:03Z W Transaction extra has unsupported format: fixture-transaction-id
2026-10-01T01:00:04Z W Transaction extra has unsupported format: fixture-transaction-id
PASSWORD=unpublished-log-secret PRIVATE_VIEW_KEY=unpublished-view-key
EOF
cat >"$TD/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$WALLET_TEST_COMMANDS"
case "$1" in
inspect)
    case "$*" in
    *'id={{.Id}}'*) echo 'id=abc started=now exit=0 oom_killed=false restarts=40 health={"Log":[{"Output":"wallet_rpc=answering wallet_height=10 daemon_height=1000"}]}' ;;
    *State.Health*) echo '{"Log":[{"Output":"wallet_rpc=unreachable scan_grace=active PASSWORD=diagnostic-secret"}]}' ;;
    *) echo 'id=abc started=now exit=0 oom_killed=false restarts=40' ;;
    esac ;;
exec)
    case "$*" in
    *'test ! -e'*) exit "${WALLET_TEST_MARKER_RC:-1}" ;;
    *) raw=$(cat); printf '%s\n' "$raw" >>"$WALLET_TEST_COMMANDS"
       script=$(printf '%s' "$raw" | sed "s|/sys/fs/cgroup|$WALLET_TEST_CGROUP|g; s|/proc/1/status|$WALLET_TEST_PROC_STATUS|g; s|/proc/1/io|$WALLET_TEST_PROC_IO|g; s|/proc/1/stat\\b|$WALLET_TEST_PROC_STAT|g; s|/proc/1/wchan|$WALLET_TEST_PROC_WCHAN|g")
       sh -c "$script" ;;

    esac ;;
logs)
    if [ "${WALLET_TEST_LOG_RC:-0}" != 0 ]; then echo 'docker read error: fixture-private-error' >&2; exit "$WALLET_TEST_LOG_RC"; fi
    if [ "${WALLET_TEST_LOG_STDERR:-0}" = 1 ]; then cat "$WALLET_TEST_LOG" >&2; else cat "$WALLET_TEST_LOG"; fi ;;
events) echo '123 action=oom exit='; echo '124 action=die exit=137' ;;
esac
EOF
cat >"$TD/bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
*get_block_count*) [ "${WALLET_TEST_DAEMON_RC:-0}" = 0 ] || exit "$WALLET_TEST_DAEMON_RC"; echo '{"id":"0","jsonrpc":"2.0","result":{"count":1000,"status":"OK","untrusted":false}}' ;;
*get_height*) if [ -n "${WALLET_TEST_HEIGHT_BODY:-}" ]; then echo "$WALLET_TEST_HEIGHT_BODY"; exit "${WALLET_TEST_HEIGHT_RC:-0}"; fi
    [ "${WALLET_TEST_HEIGHT_RC:-0}" = 0 ] || exit "$WALLET_TEST_HEIGHT_RC"; echo "{\"id\":\"0\",\"jsonrpc\":\"2.0\",\"result\":{\"height\":${WALLET_TEST_HEIGHT:-10}}}" ;;
*get_version*) exit "${WALLET_TEST_RPC_RC:-0}" ;;
esac
EOF
chmod +x "$TD/bin/"*
export PATH="$TD/bin:$PATH"
rx() { bash -c "$1"; }

echo "== wallet diagnostics: earlier OOM persists after current State resets =="
body="$(wallet_scan_sample)"
assert_contains "current restarted process is captured" "$body" 'exit=0 oom_killed=false restarts=40'
assert_contains "previous OOM survives current-state reset" "$body" 'action=oom'
assert_contains "previous fatal exit survives current-state reset" "$body" 'action=die exit=137'
assert_contains "memory peak is captured alongside current usage" "$body" $'memory.peak:\n2147483648'
assert_contains "scan position survives restart in the sampled health history" "$body" 'wallet_height=10 daemon_height=1000'
assert_contains "cache size is measured without exposing content" "$body" 'wallet_cache_bytes=13'
assert_contains "key file size is measured without exposing content" "$body" 'wallet_keys_bytes=12'
assert_contains "read demand is measured" "$body" 'rchar: 2000000000'
assert_contains "CPU work and identity are sampled without the command name" "$body" 'process_state=R cpu_user_ticks=12345 cpu_system_ticks=678 process_start_ticks=98765'
printf '1 (changed name) S 0 0 0 0 0 0 0 0 0 0 12445 690 0 0 0 0 0 0 98765\n' >"$TD/process-stat"
body="$(wallet_scan_sample)"
assert_contains "later polls distinguish increasing CPU from a sleeping process" "$body" 'process_state=S cpu_user_ticks=12445 cpu_system_ticks=690 process_start_ticks=98765'
assert_contains "kernel wait channel is sampled" "$body" 'process_wait_channel=0'
assert_contains "write demand is measured" "$body" 'write_bytes: 4096'
assert_contains "numeric scan and daemon heights are sampled directly" "$body" 'sample_wallet_height=10 sample_daemon_height=1000'
export WALLET_TEST_HEIGHT_RC=7
body="$(wallet_scan_sample)"
assert_contains "silent wallet RPC retains readable daemon height" "$body" 'sample_wallet_height=unavailable sample_daemon_height=1000'
export WALLET_TEST_DAEMON_RC=7
body="$(wallet_scan_sample)"
assert_contains "failed RPC probes are explicit rather than zero heights" "$body" 'sample_wallet_height=unavailable sample_daemon_height=unavailable'
unset WALLET_TEST_HEIGHT_RC WALLET_TEST_DAEMON_RC
for payload in '{"error":{"code":-1,"data":{"height":9999}}}' '{"result":{"height":10.5}}' 'not-json' '{"id":"0","jsonrpc":"2.0","result":{"height":1 0}}' '{"id":" 0","jsonrpc":"2.0","result":{"height":10}}' '{"id":"0","jsonrpc":"2.0","result":{"height":01}}' '{"id":"0","jsonrpc":"2.0","result":{"height":10}' '{"id":"0","jsonrpc":"2.0","result":{"metadata":{"height":10}}}' '{"error":{"code":-1},"id":"0","jsonrpc":"2.0","result":{"height":10}}'; do
    export WALLET_TEST_HEIGHT_BODY="$payload"
    body="$(wallet_scan_sample)"
    assert_contains "invalid or error RPC responses cannot become a numeric height" "$body" 'sample_wallet_height=unavailable sample_daemon_height=1000'
done
export WALLET_TEST_HEIGHT_BODY=$'{\n  "id": "0", "jsonrpc": "2.0", "result": {"height": 20}\n}'
body="$(wallet_scan_sample)"
assert_contains "formatted valid JSON retains its numeric height" "$body" 'sample_wallet_height=20 sample_daemon_height=1000'
export WALLET_TEST_HEIGHT_RC=7
body="$(wallet_scan_sample)"
assert_contains "failed curl with a response body cannot establish a height" "$body" 'sample_wallet_height=unavailable sample_daemon_height=1000'
unset WALLET_TEST_HEIGHT_BODY WALLET_TEST_HEIGHT_RC
printf 'malformed stat\n' >"$TD/process-stat"
body="$(wallet_scan_sample)"
assert_contains "malformed CPU metadata is explicitly unavailable" "$body" 'process_cpu=unavailable'
rm "$TD/process-stat"
body="$(wallet_scan_sample)"
assert_contains "missing CPU metadata is explicitly unavailable" "$body" 'process_cpu=unavailable'
assert_eq "cache content is never emitted" "$(printf '%s' "$body" | grep -c cache-fixture)" 0
assert_contains "process demand is captured" "$body" 'Threads: 32'
commands="$(cat "$WALLET_TEST_COMMANDS")"
assert_contains "events end at a timestamp instead of following forever" "$commands" '--until'
assert_contains "recent event window is bounded" "$commands" '--since 60s'
assert_contains "event fields exclude arbitrary Actor attributes" "$commands" 'index .Actor.Attributes "exitCode"'
assert_contains "v1 memory peak fallback is requested" "$commands" 'memory.max_usage_in_bytes'
assert_contains "v2 memory OOM counters are requested" "$commands" 'memory.events'
rm "$TD/cgroup/"memory.*
printf '1700000000\n' >"$TD/cgroup/memory/memory.usage_in_bytes"
printf '2100000000\n' >"$TD/cgroup/memory/memory.max_usage_in_bytes"
body="$(wallet_scan_sample)"
assert_contains "v1 current usage is measured when v2 files are absent" "$body" $'memory.usage_in_bytes:\n1700000000'
assert_contains "v1 peak is measured when v2 files are absent" "$body" $'memory.max_usage_in_bytes:\n2100000000'
rm "$TD/wallet/payout-wallet.keys"
body="$(wallet_scan_sample)"
assert_contains "unavailable metadata is explicit" "$body" 'wallet_keys_bytes=unavailable'
echo "== wallet startup log: labels survive a noisy final tail without raw contents =="
body="$(wallet_startup_sample)"
assert_contains "startup records existing-wallet entrypoint" "$body" 'wallet_startup_stage=entrypoint_reopen'
assert_contains "startup records native loading milestone" "$body" 'wallet_startup_stage=loading'
assert_contains "startup records loaded keys without the address" "$body" 'wallet_startup_stage=keys_loaded'
assert_contains "transaction work warnings are counted without identifiers" "$body" 'wallet_log_transaction_format_warnings=2'
assert_contains "log reader success is explicit" "$body" 'wallet_startup_log_exit=0'
assert_eq "startup labels omit addresses, identifiers and private log content" "$(printf '%s' "$body" | grep -Ec 'fixture-address|fixture-transaction-id|unpublished')" 0
cat >>"$WALLET_TEST_LOG" <<'EOF'
Creating view-only payout wallet at restore height 0
wallet cache missing: fixture-private-path
Failed to open portable binary, trying unportable
Initial refresh failed: fixture-private-error
Wallet initialization failed: fixture-private-error
Detaching blockchain on height 1000: fixture-private-value
Re-processing wallet existing txs starting from height 500: fixture-private-value
Starting wallet RPC server
Starting wallet RPC server
EOF
for ((i = 0; i < 300; i++)); do echo 'unrelated noisy fixture-private-value'; done >>"$WALLET_TEST_LOG"
body="$(wallet_startup_sample)"
assert_eq "a repeated startup milestone is emitted once" "$(printf '%s' "$body" | grep -cx wallet_startup_stage=rpc_started)" 1
for milestone in entrypoint_create cache_missing cache_format_fallback initial_refresh_failed initialization_failed; do
    assert_contains "startup milestone $milestone is retained before a noisy tail" "$body" "wallet_startup_stage=$milestone"
done
assert_contains "native detach and rescan heights exclude trailing private context" "$body" 'wallet_log_detach_height=1000 wallet_log_rescan_from_height=500'
assert_eq "all native error details and trailing context are omitted" "$(printf '%s' "$body" | grep -c fixture-private)" 0
export WALLET_TEST_LOG_STDERR=1
body="$(wallet_startup_sample)"
assert_contains "container stderr milestones are retained" "$body" 'wallet_startup_stage=keys_loaded'
assert_contains "container stderr transaction warnings are counted" "$body" 'wallet_log_transaction_format_warnings=2'
unset WALLET_TEST_LOG_STDERR
export WALLET_TEST_LOG_RC=7
body="$(wallet_startup_sample)"
assert_contains "unreadable retained log is explicit rather than silent success" "$body" 'wallet_startup_log_exit=7'
assert_eq "raw Docker reader errors are never emitted" "$(printf '%s' "$body" | grep -c fixture-private-error)" 0
unset WALLET_TEST_LOG_RC
capture_wallet_diagnostics "$TD"
export IT_PITHEAD=true
api_state() { echo '{}'; }
capture_artifacts route "$TD/out" >/dev/null 2>&1
assert_contains "failure capture routes wallet health into its artifact directory" "$(cat "$TD/out/route/wallet-health.json")" 'scan_grace=active'
assert_contains "failure capture routes retained events into its artifact directory" "$(cat "$TD/out/route/wallet-memory-events.txt")" 'action=die exit=137'
assert_contains "failure capture retains startup milestones separately" "$(cat "$TD/wallet-startup.txt")" 'wallet_startup_stage=keys_loaded'
assert_contains "wallet health grace reason is retained" "$(cat "$TD/wallet-health.json")" 'scan_grace=active'
assert_contains "wallet health output passes through redaction" "$(cat "$TD/wallet-health.json")" 'PASSWORD=<redacted>'
assert_eq "raw diagnostic secret is absent" "$(grep -c diagnostic-secret "$TD/wallet-health.json")" 0
body="$(_pred_monero_wallet_caught_up)"
rc=$?
assert_rc "marker still present keeps the scan predicate false" "$rc" 1
assert_contains "scan polls preserve startup evidence before final failure capture" "$body" 'wallet_startup_stage=keys_loaded'
assert_contains "scan polls retain samples before final failure capture" "$body" 'action=die exit=137'
export WALLET_TEST_MARKER_RC=0
_pred_monero_wallet_caught_up >/dev/null
assert_rc "diagnostics do not change marker-based success" "$?" 0
# Unavailable diagnostics do not bypass or fail the actual scan predicate.
wallet_scan_sample() { return 1; }
_pred_monero_wallet_caught_up >/dev/null
assert_rc "a diagnostic error leaves the readiness predicate intact" "$?" 0

echo "== wallet health reasons: scan grace is distinguishable from RPC progress =="
HC="$HERE/../../../build/monero/wallet-healthcheck.sh"
export WALLET_DIR="$TD/wallet"
touch "$WALLET_DIR/.payout-scanning"
export WALLET_TEST_RPC_RC=7
body="$(sh "$HC" 2>/dev/null)"
rc=$?
assert_rc "silent RPC remains tolerated within the existing grace" "$rc" 0
assert_contains "silent scan grace has an explicit reason" "$body" 'wallet_rpc=unreachable scan_grace=active'
body="$(PAYOUT_SCAN_GRACE_SEC=0 sh "$HC" 2>/dev/null)"
rc=$?
assert_rc "expired scan grace still fails" "$rc" 1
assert_contains "expired grace has an explicit reason" "$body" 'scan_grace=inactive'
export WALLET_TEST_RPC_RC=0
body="$(sh "$HC")"
rc=$?
assert_rc "answering wallet behind tip stays healthy" "$rc" 0
assert_contains "height diagnostics establish scan position" "$body" 'wallet_height=10 daemon_height=1000'
assert_eq "behind-tip scan retains its marker" "$(test -f "$WALLET_DIR/.payout-scanning" && echo present)" present
export WALLET_TEST_HEIGHT=1000
sh "$HC" >/dev/null
assert_eq "catch-up still clears the scan marker" "$(test -f "$WALLET_DIR/.payout-scanning" && echo present)" ''
body="$(sh "$HC")"
assert_contains "strict healthy mode has an explicit reason" "$body" 'wallet_rpc=answering scan_marker=absent'
export WALLET_TEST_RPC_RC=7
sh "$HC" >/dev/null 2>&1
assert_rc "RPC failure after catch-up still fails" "$?" 1
echo "== wallet startup: one parallel worker on creation and reopen =="
export WALLET_TEST_ARGV="$TD/argv"
cat >"$TD/bin/monero-wallet-rpc" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$WALLET_TEST_ARGV"
EOF
chmod +x "$TD/bin/monero-wallet-rpc"
ENTRYPOINT="$HERE/../../../build/monero/wallet-entrypoint.sh"
for mode in create reopen; do
    d="$TD/start-$mode"
    mkdir -p "$d"
    [ "$mode" != reopen ] || printf 'persisted-wallet' >"$d/payout-wallet"
    WALLET_DIR="$d" GEN_JSON="$d/gen.json" MONERO_VIEW_KEY=fixture-view-key bash "$ENTRYPOINT" >/dev/null
    rc=$?
    assert_rc "wallet $mode still invokes the daemon" "$rc" 0
    assert_eq "wallet $mode limits parallel work to one worker" "$(grep -A1 -x -- --max-concurrency "$WALLET_TEST_ARGV" | tail -1)" 1
    assert_eq "wallet $mode supplies only one concurrency bound" "$(grep -cx -- --max-concurrency "$WALLET_TEST_ARGV")" 1
    assert_eq "wallet $mode does not skip initial sync" "$(grep -cx -- --no-initial-sync "$WALLET_TEST_ARGV")" 0
    assert_eq "wallet $mode keeps view material off argv" "$(grep -c fixture-view-key "$WALLET_TEST_ARGV")" 0
    if [ "$mode" = reopen ]; then
        assert_eq "reopen preserves cached wallet content" "$(cat "$d/payout-wallet")" persisted-wallet
        assert_eq "reopen does not regenerate the wallet" "$(test -f "$d/gen.json" && echo present)" ''
    else
        assert_eq "create writes the existing key-generation input" "$(test -f "$d/gen.json" && echo present)" present
    fi
done
echo "== wallet prerequisite: answering RPC behind the tip is not caught up =="
# Poll once against the real predicates, without sleeping through the production bounds.
wait_for() { "$4" "${@:5}"; }
api_state() { printf '%s\n' "$WALLET_TEST_STATE"; }
WALLET_TEST_STATE='{"earnings":{"confirmed":{"reachable":true,"address_match":true}}}'
export WALLET_TEST_MARKER_RC=1
fails="$(
    IT_FAIL=0
    assert_payout_wallet_ready confirmed Monero >/dev/null
    echo "$IT_FAIL"
)"
assert_eq "reachable matching RPC with a scan marker still fails catch-up" "$fails" 1
export WALLET_TEST_MARKER_RC=0
fails="$(
    IT_FAIL=0
    assert_payout_wallet_ready confirmed Monero >/dev/null
    echo "$IT_FAIL"
)"
assert_eq "caught-up reachable matching wallet passes prerequisite" "$fails" 0
WALLET_TEST_STATE='{"earnings":{"confirmed":{"reachable":false,"address_match":null}}}'
fails="$(
    IT_FAIL=0
    assert_payout_wallet_ready confirmed Monero >/dev/null
    echo "$IT_FAIL"
)"
assert_eq "catch-up alone cannot bypass reachability and address checks" "$fails" 2
printf 'selftest-wallet-diagnostics: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
