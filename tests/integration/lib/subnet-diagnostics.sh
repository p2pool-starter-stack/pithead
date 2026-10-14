# shellcheck shell=bash
# Read-only capture at the first readiness timeout, before further waits or restoration.
collect_subnet_diagnostics() { # <artifact directory>
    local dir="$1" rc=0
    mkdir -p "$dir" || return 1
    rx 'timeout --kill-after=2 120 python3 tests/integration/subnet-diagnostics.py' \
        >"$dir/summary.jsonl" 2>/dev/null || rc=$?
    printf 'collector_exit=%s\n' "$rc" >"$dir/collector-exit.txt" || return 1
    return "$rc"
}

run_subnet_diagnostics_smoke() {
    local dir="$OUT_DIR/subnet-diagnostics-smoke" rc=0 probe
    collect_subnet_diagnostics "$dir" || rc=$?
    assert_rc "subnet diagnostics: bounded collector completes" "$rc" 0
    for probe in rendered-network container-monerod container-tari container-tor container-dashboard container-p2pool container-xmrig-proxy monero-admin-info monero-get_connections monero-sync_info tor-circuit-status tor-stream-status tor-build-history live-network monero-proxy tor-control-bind firewall-enforcement; do
        jq -es --arg probe "$probe" 'any(.[]; .probe == $probe and has("summary") and (has("error") | not))' \
            "$dir/summary.jsonl" >/dev/null 2>&1
        assert_rc "subnet diagnostics: $probe readable" "$?" 0
    done
    jq -es 'any(.[]; .probe == "monero-admin-info" and .summary.rpc_visibility == "unrestricted") and any(.[]; .probe == "collection" and .complete == true)' \
        "$dir/summary.jsonl" >/dev/null 2>&1
    assert_rc "subnet diagnostics: authenticated admin readings and completion retained" "$?" 0
    jq -es 'any(.[]; (.probe == "firewall-iptables" or .probe == "firewall-nft") and (has("error") | not) and .summary.count > 0)' \
        "$dir/summary.jsonl" >/dev/null 2>&1
    assert_rc "subnet diagnostics: live firewall counters retained" "$?" 0
}

capture_subnet_timeout_once() {
    [ "${SUBNET_TIMEOUT_ACTIVE:-0}" = 1 ] || return 0
    [ "${SUBNET_TIMEOUT_CAPTURED:-0}" = 0 ] || return 0
    SUBNET_TIMEOUT_CAPTURED=1
    local dir="$OUT_DIR/subnet-first-timeout" rc=0
    if ! mkdir -p "$dir"; then
        it_err "subnet first-timeout diagnostics: artifact directory creation failed"
        return 0
    fi
    printf 'stage=%s utc=%s\n' "$1" "$(date -u +%FT%TZ)" >"$dir/trigger.txt" || true
    # Subnet runs only in local mode. No raw stderr is retained; typed probe errors are JSONL.
    collect_subnet_diagnostics "$dir" || rc=$?
    it_step "subnet first-timeout diagnostics retained (collector exit $rc)"
    return 0
}
