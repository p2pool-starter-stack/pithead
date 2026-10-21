# shellcheck shell=bash
#
# Proves #2351 live: a first-boot wizard submission naming the bench's reserved, reachable Tari
# node by NAME is accepted and pinned to its resolved address, not refused for lacking a literal
# IPv4. Sourced by tests/os/run.sh, run inside phase_provision beside
# provision_node_preflight_retention (the sibling negative case: an unreachable name refused).
#
# Paired with a deliberately unreachable Monero endpoint so the overall submission stays refused
# (HTTP 400, the same shape as provision_node_preflight_retention) and installs nothing: the
# node_probe report is written whichever way the overall verdict lands
# (wizard_node_probe.py's probe_remote_nodes writes it before the ok/fail branch), so the Tari
# row's own verdict is readable here without touching the real, once-only accepted submission
# that follows this leg. Skips (missing, #1365 vocabulary) when the bench carries no reserved
# Tari node, or when the reserved fixture is configured as a bare IPv4 rather than a name: this
# leg exists to prove NAME resolution, and _resolved_address can only ever return a value equal
# to its input when that input already parses as an IPv4Address (job 609 read the exact case: a
# fixture supplying a literal IP always makes "resolved_host == the entered value" true, on
# CORRECT code, because there was never a name to resolve -- asserting inequality there would
# reward a fixture-shape mismatch as a product defect, not report one).

# True only for a real dotted-quad IPv4, parsed rather than glob-matched: the same shape-then-
# octet-range check lib/pithead/42-control-policy-and-host-checks.sh's _is_canonical_ipv4 makes.
# A glob like [0-9]*.[0-9]*.[0-9]*.[0-9]* also swallows genuine NAMES — `10.0.0.5.nip.io`, or any
# digit-led label with four dots — and skipping this leg on one of those would hide the very
# by-name path it exists to prove.
_reserved_node_is_ipv4() { # <host>
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    local octet
    for octet in "${BASH_REMATCH[@]:1}"; do [ "$octet" -le 255 ] || return 1; done
    return 0
}

provision_node_preflight_accepts_reserved_name() { # <ip> <authenticated-cookie-jar>
    local ip="$1" jar="$2" th="${PITHEAD_OS_TARI_NODE_HOST:-}" grpc="${PITHEAD_OS_TARI_GRPC_PORT:-}"
    local state cfg code raw body
    if [ -z "$th" ] || [ -z "$grpc" ]; then
        it_skip_leg "reserved Tari node accepted by name during first-boot provisioning (#2351)" "PITHEAD_OS_TARI_NODE_HOST/PITHEAD_OS_TARI_GRPC_PORT not supplied" missing
        return 0
    fi
    if _reserved_node_is_ipv4 "$th"; then
        it_skip_leg "reserved Tari node accepted by name during first-boot provisioning (#2351)" "PITHEAD_OS_TARI_NODE_HOST is a literal IPv4 address on this bench, not a name — pithead#2351 needs a name-shaped reserved Tari endpoint, tracked on bench-ci" missing
        return 0
    fi
    state=$(curl -fsSk -b "$jar" -m 5 "https://$ip/api/wizard-state" 2>/dev/null) || return 1
    cfg=$(printf '%s' "$state" | jq -c --arg m "$HARNESS_WALLET" --arg t "$HARNESS_TARI" --arg th "$th" --argjson grpc "$grpc" '
        .config | .monero.wallet_address = $m | .tari.wallet_address = $t |
        .monero.mode = "remote" |
        .monero.remote = {host: "unreachable.invalid", rpc_port: 18081, zmq_port: 18083} |
        .tari.mode = "remote" | .tari.remote = {host: $th, grpc_port: $grpc} |
        .p2pool.pool = "mini" | .local_miner.enabled = true') || return 1
    raw=$(curl -sSk -b "$jar" -m 30 --data-urlencode "config=$cfg" --data-urlencode "auth_mode=auto" "https://$ip/submit" -w '\n%{http_code}' 2>/dev/null)
    code=${raw##*$'\n'}
    body=${raw%$'\n'*}
    if [ "$code" != "400" ]; then
        bad "reserved-node-by-name leg did not stay side-effect-free (HTTP ${code:-none}, expected the paired Monero refusal to keep this leg from installing)"
        return 1
    fi
    if printf '%s' "$body" | jq -e --arg th "$th" '
        [.node_probe.probes[]? | select(.target == "tari")] as $rows |
        ($rows | length) > 0 and
        all($rows[]; .ok == true and .reason == "ok" and .resolved_host != "" and .resolved_host != $th)' >/dev/null; then
        ok "reserved Tari node submitted by name is accepted and pinned to its resolved address (#2351)"
    else
        bad "reserved Tari node by name was not accepted and pinned ($(printf '%s' "$body" | jq -c '.node_probe.probes[]? | select(.target=="tari")' 2>/dev/null || printf 'unreadable body'))"
        return 1
    fi
}

# Tier-1 check for the guard above, driven by tests/stack/test-harness-tooling.sh. The guard
# decides whether this leg runs at all, so a wrong answer is silent: too broad and the by-name
# proof never runs (the #2351 return), too narrow and it asserts inequality against a fixture
# that never had a name to resolve. The NAME rows are the ones the earlier dotted glob failed.
_reserved_node_is_ipv4_self_test() {
    local n=0 f=0 host want
    while read -r host want; do
        [ -n "$host" ] || continue
        n=$((n + 1))
        if _reserved_node_is_ipv4 "$host"; then [ "$want" = ip ]; else [ "$want" = name ]; fi ||
            { printf '  case %-28s wanted %s\n' "$host" "$want" && f=$((f + 1)); }
    done <<'CASES'
10.0.0.5 ip
192.168.1.172 ip
0.0.0.0 ip
255.255.255.255 ip
100.64.0.1 ip
10.0.0.5.nip.io name
1a.2b.3c.4d name
192.168.1.172.example.com name
tari-node.lan name
node.example name
256.0.0.1 name
10.0.0 name
10.0.0.5.6 name
010.0.0.5 name
10.0.0.5a name
CASES
    if [ "$f" -gt 0 ]; then
        printf '#2351 reserved-node IPv4 guard self-test FAILED: %s of %s cases\n' "$f" "$n"
        return 1
    fi
    printf '#2351 reserved-node IPv4 guard self-test passed (%s cases)\n' "$n"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--self-test" ]; then
    _reserved_node_is_ipv4_self_test
    exit $?
fi
