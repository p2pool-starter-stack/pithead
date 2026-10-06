# shellcheck shell=bash
# Extra canned readings and driver tests, called by soak-probe.sh --self-test.
soak_extended_selftest() {
    local base="$1" today out tmp value listing changed canonical rc
    # shellcheck source=tests/os/soak-read.sh
    source "$(dirname "$0")/soak-read.sh" --library
    # shellcheck source=tests/os/soak-record.sh
    source "$(dirname "$0")/soak-record.sh"
    out=$(soak_memory <<<'MemTotal: 8000 kB
MemAvailable: 3000 kB
SwapTotal: 2000 kB
SwapFree: 1500 kB')
    chk 'memory and swap use kernel KiB values' "$out" $'mem_total_kib=8000\nmem_available_kib=3000\nswap_total_kib=2000\nswap_free_kib=1500'
    out=$(soak_memory <<<'MemTotal: 8000 kB')
    chk 'missing memory reading is unknown' "$out" $'mem_total_kib=8000\nmem_available_kib=?\nswap_total_kib=?\nswap_free_kib=?'
    chk 'numeric API field cannot disclose strings' "$(soak_number tari_height wallet-secret)" 'tari_height=?'
    chk 'Monero real fields retain false sync and numeric peer counts' "$(printf '%s' '{"height":100,"synchronized":false,"incoming_connections_count":1,"outgoing_connections_count":2}' | soak_monero)" 'monero=h:100 sync:false peers:1/2'
    chk 'Monero restricted counts remain explicitly restricted' "$(printf '%s' '{"height":100,"synchronized":true,"restricted":true,"incoming_connections_count":0,"outgoing_connections_count":0}' | soak_monero)" 'monero=h:100 sync:true peers:restricted'
    chk 'Monero missing fields are unknown' "$(printf '%s' '{}' | soak_monero)" 'monero=h:? sync:? peers:?/?'
    chk 'Monero malformed JSON is unknown' "$(printf '%s' '{bad' | soak_monero)" 'monero=h:? sync:? peers:?/?'
    chk 'Monero strings cannot forge readings or disclose secrets' "$(printf '%s' '{"height":"wallet-secret\nfirewall_present=1\nfirst_sync_exemption=0", "synchronized":"secret", "incoming_connections_count":"onion-secret", "outgoing_connections_count":"rpc-secret"}' | soak_monero)" 'monero=h:? sync:? peers:?/?'
    listing='{"nftables":[{"metainfo":{"version":"1"}},{"table":{"family":"inet","name":"pithead_egress"}},{"set":{"name":"live","flags":["dynamic"],"elem":[1]}},{"set":{"name":"static","elem":[2]}}]}'
    canonical=$(printf '%s' "$listing" | soak_firewall_canonical)
    changed=$(printf '%s' "$listing" | jq '(.nftables[2].set.elem) = [9]')
    chk 'dynamic set elements do not change policy hash input' "$(printf '%s' "$changed" | soak_firewall_canonical)" "$canonical"
    changed=$(printf '%s' "$listing" | jq '(.nftables[3].set.elem) = [9]')
    value=$(printf '%s' "$changed" | soak_firewall_canonical)
    if [ "$value" != "$canonical" ]; then rc=0; else rc=1; fi
    chk 'static set elements remain policy' "$rc" 0
    printf '%s' '{"nftables":[]}' | soak_firewall_canonical >/dev/null
    chk 'missing table cannot be hashed' "$?" 4
    listing='{"nftables":[{"rule":{"chain":"forward","expr":[{"match":{"left":{"payload":{"protocol":"ip","field":"saddr"}},"right":"172.28.0.26"}},{"accept":null}]}}]}'
    printf '%s' "$listing" | soak_sync_exemption 172.28.0 >/dev/null
    chk 'live Monero first-sync exception detected' "$?" 0
    printf '%s' "${listing/.26/.27}" | soak_sync_exemption 172.28.0 >/dev/null
    chk 'live Tari first-sync exception detected' "$?" 0
    printf '%s' "${listing/.26/.25}" | soak_sync_exemption 172.28.0 >/dev/null
    chk 'Tor source accept is not a sync exception' "$?" 1
    printf '%s' '{bad json' | soak_sync_exemption 172.28.0 >/dev/null 2>&1
    value=$?
    if [ "$value" -ne 0 ]; then rc=0; else rc=1; fi
    chk 'unreadable firewall cannot clear start precondition' "$rc" 0
    for field in firewall_hash firewall_present; do
        today=$(printf '%s\n' "$base" | sed "/^$field=/d")
        out=$(soak_day_verdict "$base" "$today")
        chk "missing $field fails rule 6" "$?" 1
        chk 'firewall failure named' "${out#*fails=}" '6:firewall-missing-or-changed'
    done
    today=${base/firewall_present=1/firewall_present=0}
    out=$(soak_day_verdict "$base" "$today")
    chk 'absent firewall fails' "$?" 1
    today=$(printf '%s\n' "$base" | sed 's/^firewall_hash=.*/firewall_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/')
    out=$(soak_day_verdict "$base" "$today")
    chk 'changed firewall fails' "$?" 1
    tmp=$(mktemp -d) || {
        chk 'extended: mktemp' 1 0
        return
    }
    mkdir -p "$tmp/bin"
    printf '%s\n' '#!/usr/bin/env bash' '[ "${SOAK_REALPATH_FAIL:-0}" = 0 ] || exit 1' 'printf "%s\n" "$SOAK_RESOLVED_PATH"' >"$tmp/bin/realpath"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >"$SOAK_DU_ARGS"' 'printf "%s\tfixture\n" "${SOAK_DU_SIZE:-123}"' 'exit "${SOAK_DU_FAIL:-0}"' >"$tmp/bin/du"
    chmod +x "$tmp/bin/realpath" "$tmp/bin/du"
    out=$(PATH="$tmp/bin:$PATH" SOAK_RESOLVED_PATH=/data/fixture/monero SOAK_DU_ARGS="$tmp/du-args" soak_disk monero_chain_mib /configured/monero)
    chk 'chain collector records allocated MiB from resolved data path' "$out" 'monero_chain_mib=123'
    chk 'chain collector requests same-filesystem allocated MiB' "$(cat "$tmp/du-args")" '-sx -B1M -- /data/fixture/monero'
    out=$(PATH="$tmp/bin:$PATH" SOAK_RESOLVED_PATH=/data/fixture/tari SOAK_DU_ARGS="$tmp/du-args" SOAK_DU_SIZE=0 soak_disk tari_chain_mib /configured/tari)
    chk 'zero chain size is measured, not missing' "$out" 'tari_chain_mib=0'
    out=$(PATH="$tmp/bin:$PATH" SOAK_RESOLVED_PATH=/data/fixture/tari SOAK_DU_ARGS="$tmp/du-args" SOAK_DU_FAIL=1 soak_disk tari_chain_mib /configured/tari)
    chk 'failed du with partial total is unknown' "$out" 'tari_chain_mib=?'
    rm -f "$tmp/du-args"
    out=$(PATH="$tmp/bin:$PATH" SOAK_REALPATH_FAIL=1 SOAK_RESOLVED_PATH='' SOAK_DU_ARGS="$tmp/du-args" soak_disk tari_chain_mib /missing)
    chk 'missing chain path is unknown' "$out" 'tari_chain_mib=?'
    out=$(PATH="$tmp/bin:$PATH" SOAK_RESOLVED_PATH=/outside/fixture SOAK_DU_ARGS="$tmp/du-args" soak_disk tari_chain_mib /data/escape)
    chk 'escaped data path is unknown' "$out" 'tari_chain_mib=?'
    if [ ! -e "$tmp/du-args" ]; then rc=0; else rc=1; fi
    chk 'du never runs for missing or escaped data paths' "$rc" 0
    rm "$tmp/bin/realpath" "$tmp/bin/du"
    mkdir -p "$tmp/pool/stats/local" "$tmp/pool/stats/pool"
    printf '{"hashrate_15m":50,"shares_found":6,"shares_failed":0,"wallet":"secret"}' >"$tmp/pool/stats/local/stratum"
    printf '{"pool_statistics":{"sidechainHeight":100}}' >"$tmp/pool/stats/pool/stats"
    chk 'actual P2Pool schema selects only mining readings' "$(soak_p2pool "$tmp/pool")" $'p2pool_hashrate=50\np2pool_shares_found=6\np2pool_shares_failed=0\np2pool_sidechain_height=100'
    chk 'missing P2Pool files record every field as unknown' "$(soak_p2pool "$tmp/absent")" $'p2pool_hashrate=?\np2pool_shares_found=?\np2pool_shares_failed=?\np2pool_sidechain_height=?'
    chk 'container memory and CPU recorded' "$(printf 'monerod|12MiB / 2GiB|1.5%%\n' | soak_container_stats)" 'container_stats=monerod|12MiB / 2GiB|1.5%'
    chk 'unavailable container stats recorded' "$(printf '' | soak_container_stats)" 'container_stats=?'
    chk 'malformed container stats cannot disclose strings' "$(printf 'monerod|wallet-secret|secret\n' | soak_container_stats)" 'container_stats=monerod|?|?'
    mkdir -p "$tmp/bin"
    printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'cat "$SOAK_STUB_READING"' >"$tmp/bin/ssh"
    chmod +x "$tmp/bin/ssh"
    drv_ext() { PATH="$tmp/bin:$PATH" SOAK_STUB_READING="$tmp/$1" bash "$0" stub-host "$tmp/log" "${2:-}"; }
    printf '%s\n' "$base" >"$tmp/base"
    printf '%s\n' "${base/first_sync_exemption=0/first_sync_exemption=1}" >"$tmp/exemption"
    drv_ext exemption --start >/dev/null 2>&1
    chk 'start refuses first-sync exemption' "$?" 1
    if [ ! -f "$tmp/log/day0.env" ]; then rc=0; else rc=1; fi
    chk 'refused start never writes baseline' "$rc" 0
    drv_ext base --read >/dev/null
    chk 'live-read mode does not need baseline' "$?" 0
    if [ ! -f "$tmp/log/started" ]; then rc=0; else rc=1; fi
    chk 'live-read mode never opens soak window' "$rc" 0
    if [ -s "$tmp/log/read.env" ]; then rc=0; else rc=1; fi
    chk 'live-read mode retains readings' "$rc" 0
    printf '%s\n' '#!/usr/bin/env bash' 'if [ "$2" = -i ]; then cat >/dev/null; printf "%s\n" "$SOAK_REPLY"; exit "${SOAK_STUB_FAILURE:-0}"; fi' 'printf "%s\n" "${SOAK_TOR_CANNED:-}"; exit "${SOAK_STUB_FAILURE:-0}"' >"$tmp/bin/podman"
    chmod +x "$tmp/bin/podman"
    env_get() { [ "$1" != TARI_MODE ] || printf '%s' "${SOAK_TARI_MODE:-local}"; }
    value=$'tari_height=123\nproxy_workers=2\nproxy_accepted=50\nproxy_rejected=0'
    out=$(PATH="$tmp/bin:$PATH" SOAK_REPLY="$value" soak_api)
    chk 'actual API wrapper records tip and proxy counters' "$out" "$value"
    out=$(PATH="$tmp/bin:$PATH" SOAK_REPLY="$value" SOAK_TARI_MODE=remote soak_api)
    chk 'remote Tari is not attributed to local node' "$out" "${value/tari_height=123/tari_height=?}"
    out=$(PATH="$tmp/bin:$PATH" SOAK_REPLY='' SOAK_STUB_FAILURE=1 soak_api)
    chk 'unavailable API records every field as unknown' "$out" $'tari_height=?\nproxy_workers=?\nproxy_accepted=?\nproxy_rejected=?'
    out=$(PATH="$tmp/bin:$PATH" SOAK_REPLY='tari_height=wallet-secret' soak_api)
    chk 'API wrapper cannot disclose string values' "$out" $'tari_height=?\nproxy_workers=?\nproxy_accepted=?\nproxy_rejected=?'
    out=$(PATH="$tmp/bin:$PATH" soak_tor)
    chk 'successful authenticated Tor check records 100 percent' "$out" 'tor_bootstrap_pct=100'
    out=$(PATH="$tmp/bin:$PATH" SOAK_STUB_FAILURE=1 SOAK_TOR_CANNED='Tor health: bootstrap progress=75 tag=loading.' soak_tor)
    chk 'incomplete Tor bootstrap records progress' "$out" 'tor_bootstrap_pct=75'
    out=$(PATH="$tmp/bin:$PATH" SOAK_STUB_FAILURE=1 SOAK_TOR_CANNED='Tor health: control cookie unavailable.' soak_tor)
    chk 'unavailable Tor progress records unknown' "$out" 'tor_bootstrap_pct=?'
    unset -f env_get
    # Execute the actual embedded API program with fake modules, not an alternative parser.
    python3 - "$(dirname "$0")/soak-read.sh" <<'API_TEST'
import contextlib
import io
import os
import sys
import types
from unittest.mock import patch

source = open(sys.argv[1]).read()
code = source.split("<<'API'\n", 1)[1].split("\nAPI\n", 1)[0]
summary = {"miners": {"now": 2}, "results": {"accepted": 50, "rejected": 0}, "wallet": "secret"}
tip = types.SimpleNamespace(metadata=types.SimpleNamespace(best_block_height=123))
fail = False
calls = []
class Channel:
    def __enter__(self): return self
    def __exit__(self, *args): pass
class Stub:
    def __init__(self, channel): pass
    def GetTipInfo(self, request, timeout):
        assert timeout == 5
        if fail: raise RuntimeError("secret")
        return tip
class Response:
    def raise_for_status(self):
        if fail: raise RuntimeError("secret")
    def json(self): return summary
def get(url, headers, timeout):
    calls.append((url, headers, timeout))
    return Response()
modules = {name: types.ModuleType(name) for name in (
    "grpc", "requests", "google", "google.protobuf", "google.protobuf.empty_pb2",
    "mining_dashboard", "mining_dashboard.client", "mining_dashboard.client.tari",
    "mining_dashboard.client.tari.generated", "mining_dashboard.client.tari.generated.base_node_pb2_grpc")}
modules["grpc"].insecure_channel = lambda address: Channel()
modules["requests"].get = get
modules["google.protobuf.empty_pb2"].Empty = lambda: None
modules["mining_dashboard.client.tari.generated.base_node_pb2_grpc"].BaseNodeStub = Stub
with patch.dict(sys.modules, modules), patch.dict(os.environ, {"TARI_GRPC_ADDRESS": "node.invalid:18142", "PROXY_HOST": "proxy.invalid", "PROXY_API_PORT": "3344", "PROXY_AUTH_TOKEN": "secret"}, clear=True):
    def run():
        output = io.StringIO()
        with contextlib.redirect_stdout(output): exec(code, {})
        return output.getvalue()
    assert run() == "tari_height=123\nproxy_workers=2\nproxy_accepted=50\nproxy_rejected=0\n"
    assert calls[-1] == ("http://proxy.invalid:3344/1/summary", {"Authorization": "Bearer secret"}, 5)
    fail = True
    assert run() == "tari_height=?\nproxy_workers=?\nproxy_accepted=?\nproxy_rejected=?\n"
    fail = False
    summary = {}; tip.metadata.best_block_height = "secret"
    assert run() == "tari_height=?\nproxy_workers=?\nproxy_accepted=?\nproxy_rejected=?\n"
    summary = {"miners": {"now": "secret"}, "results": {"accepted": True, "rejected": -1}}
    assert "secret" not in run() and "proxy_workers=?" in run()
API_TEST
    chk 'real API program measured, missing, error and secret fixtures' "$?" 0
    printf '%s\nmem_total_kib=8000\nmem_available_kib=3000\nmonero_chain_mib=100\ntari_chain_mib=200\ncontainer_stats=monerod|12MiB / 2GiB|1.5%%\n' "$base" >"$tmp/a"
    drv_ext a --start >/dev/null
    chk 'metrics are recorded without gating' "$?" 0
    out=$(cat "$tmp/log/read1.env")
    chk 'initial sampled maximum is used RAM' "$(printf '%s\n' "$out" | sed -n 's/^mem_sampled_max_kib=//p')" 5000
    # Make the interval deterministic for growth arithmetic.
    sed -i "s/^sample_epoch=.*/sample_epoch=$(($(date +%s) - 86400))/" "$tmp/log/read1.env"
    sed 's/mem_available_kib=3000/mem_available_kib=2000/;s/monero_chain_mib=100/monero_chain_mib=110/' "$tmp/a" >"$tmp/b"
    drv_ext b >/dev/null
    chk 'changed resources do not gate' "$?" 0
    out=$(cat "$tmp/log/read2.env")
    chk 'sampled maximum rises' "$(printf '%s\n' "$out" | sed -n 's/^mem_sampled_max_kib=//p')" 6000
    chk 'chain growth is measured since previous read' "$(printf '%s\n' "$out" | sed -n 's/^monero_growth_mib=//p')" 10
    chk 'chain growth per day uses elapsed sample time' "$(printf '%s\n' "$out" | sed -n 's/^monero_growth_mib_per_day=//p')" '10.000'
    drv_ext a >/dev/null
    out=$(cat "$tmp/log/read3.env")
    chk 'lower reading preserves sampled maximum' "$(printf '%s\n' "$out" | sed -n 's/^mem_sampled_max_kib=//p')" 6000
    sed '/^mem_/d;/^monero_chain_mib=/d' "$tmp/a" >"$tmp/missing"
    drv_ext missing >/dev/null
    chk 'missing recorded readings do not gate' "$?" 0
    out=$(tail -1 "$tmp/log/soak.log")
    if [[ "$out" == *'mem_total_kib=?'* && "$out" == *'monero_chain_mib=?'* && "$out" == *'tari_height=?'* ]]; then rc=0; else rc=1; fi
    chk 'summary names missing readings as unknown' "$rc" 0
    if [[ "$out" == *'firewall_listing'* || "$out" == *'wallet-secret'* ]]; then rc=0; else rc=1; fi
    chk 'summary excludes private listings and secrets' "$rc" 1
    drv_ext a --start >/dev/null
    out=$(cat "$tmp/log/read5.env")
    chk 'new start resets sampled maximum' "$(printf '%s\n' "$out" | sed -n 's/^mem_sampled_max_kib=//p')" 5000
    printf '%s\n' "$today" >"$tmp/changed"
    drv_ext changed >/dev/null
    chk 'driver fails changed firewall' "$?" 1
    cmp -s "$tmp/log/day0.firewall.json" "$tmp/log/read6.firewall-baseline.json"
    chk 'mismatch retains day-0 listing beside daily record' "$?" 0
    if [ -s "$tmp/log/read6.firewall-current.json" ]; then rc=0; else rc=1; fi
    chk 'mismatch retains current listing beside daily record' "$rc" 0
    # A failed SSH sample occupies a read number but writes no predecessor env.
    rm -rf "$tmp/log"
    drv_ext a --start >/dev/null
    drv_ext b >/dev/null
    drv_ext absent >/dev/null 2>&1
    chk 'failed SSH sample fails the read' "$?" 1
    if [ ! -e "$tmp/log/read3.env" ]; then rc=0; else rc=1; fi
    chk 'failed SSH sample leaves no readings record' "$rc" 0
    sed 's/monero_chain_mib=100/monero_chain_mib=120/;s/tari_chain_mib=200/tari_chain_mib=220/' "$tmp/a" >"$tmp/recovered"
    drv_ext recovered >/dev/null
    chk 'SSH recovery records a successful sample' "$?" 0
    out=$(cat "$tmp/log/read4.env")
    for key in monero_growth_mib monero_growth_mib_per_day tari_growth_mib tari_growth_mib_per_day; do
        chk "SSH recovery leaves $key unavailable across missing predecessor" "$(printf '%s\n' "$out" | sed -n "s/^$key=//p")" '?'
    done
    sed 's/monero_chain_mib=120/monero_chain_mib=130/;s/tari_chain_mib=220/tari_chain_mib=230/' "$tmp/recovered" >"$tmp/next"
    drv_ext next >/dev/null
    out=$(cat "$tmp/log/read5.env")
    for chain in monero tari; do
        chk "next successful read resumes $chain growth from recovery" "$(printf '%s\n' "$out" | sed -n "s/^${chain}_growth_mib=//p")" 10
    done
    # The KVM row must fail if a required collector field disappears.
    printf '%s\nmem_total_kib=8000\nmem_available_kib=3000\ncontainer_stats=?\n' "$base" >"$tmp/live"
    for key in swap_total_kib swap_free_kib monero_chain_mib tari_chain_mib tari_height p2pool_hashrate p2pool_shares_found p2pool_shares_failed p2pool_sidechain_height proxy_workers proxy_accepted proxy_rejected tor_bootstrap_pct; do printf '%s=?\n' "$key" >>"$tmp/live"; done
    soak_live_read_verdict "$tmp/live"
    chk 'live proof accepts explicitly unknown optional readings' "$?" 0
    sed '/^tari_height=/d' "$tmp/live" >"$tmp/live-missing"
    soak_live_read_verdict "$tmp/live-missing"
    chk 'live proof fails a silently missing instrument' "$?" 1
    sed 's/^mem_total_kib=.*/mem_total_kib=?/' "$tmp/live" >"$tmp/live-missing"
    soak_live_read_verdict "$tmp/live-missing"
    chk 'live proof requires measured host memory' "$?" 1
    sed 's/^firewall_present=.*/firewall_present=0/' "$tmp/live" >"$tmp/live-missing"
    soak_live_read_verdict "$tmp/live-missing"
    chk 'live proof requires an actual firewall table' "$?" 1
    rm -rf "$tmp"
}
