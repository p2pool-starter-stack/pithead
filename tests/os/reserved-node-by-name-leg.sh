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
provision_node_preflight_accepts_reserved_name() { # <ip> <authenticated-cookie-jar>
    local ip="$1" jar="$2" th="${PITHEAD_OS_TARI_NODE_HOST:-}" grpc="${PITHEAD_OS_TARI_GRPC_PORT:-}"
    local state cfg code raw body
    if [ -z "$th" ] || [ -z "$grpc" ]; then
        it_skip_leg "reserved Tari node accepted by name during first-boot provisioning (#2351)" "PITHEAD_OS_TARI_NODE_HOST/PITHEAD_OS_TARI_GRPC_PORT not supplied" missing
        return 0
    fi
    case "$th" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*)
        it_skip_leg "reserved Tari node accepted by name during first-boot provisioning (#2351)" "PITHEAD_OS_TARI_NODE_HOST is a literal IPv4 address on this bench, not a name -- a differently-configured bench's name-shaped fixture would exercise this leg" missing
        return 0
        ;;
    esac
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
