# shellcheck shell=bash
# Bounded XvB actuation smoke for the throwaway KVM appliance. The appliance is
# intentionally unsynchronised, so this injects the controller's existing switch
# method rather than pretending a PPLNS share or routed hashrate exists.

_xvb_payload() { # <mode> -> base64 Python that actuates then reads the live route
    case "$1" in P2POOL | XVB) ;; *) return 2 ;; esac
    printf '%s\n' "import asyncio, json" "from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient" \
        "from mining_dashboard.config.config import PROXY_API_PORT, PROXY_AUTH_TOKEN, PROXY_HOST" \
        "from mining_dashboard.service.storage_service import StateManager" \
        "from mining_dashboard.service.xvb.algo_service import AlgoService" \
        "async def main():" \
        "    state = StateManager()" \
        "    client = XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN)" \
        "    await AlgoService(state, client, None).switch_miners('$1')" \
        "    pools = client.get_config().get('pools', [])" \
        "    print(json.dumps({'mode': state.get_xvb_stats().get('mode'), 'pools': [{'enabled': p.get('enabled'), 'tor': bool(p.get('socks5'))} for p in pools]}))" \
        "asyncio.run(main())" |
        base64 | tr -d '\n'
}

_xvb_guest_python() { _ssh "printf %s '$1' | base64 -d | podman exec -i dashboard python3 -"; }

_xvb_real_tor_fetch() {
    local payload
    payload="$(base64 <"$SCRIPT_DIR/../integration/lib/xvb-egress-probe.py" | tr -d '\n')"
    _xvb_guest_python "$payload"
}

phase_provision_xvb_routing() ( # <dashboard user> <dashboard password>
    # shellcheck disable=SC2034 # dashboard_curl reads these through dynamic scope.
    local DASH_USER="$1" DASH_PASS="$2" pools state rc=0
    info "provision leg — bounded XvB routing injection"
    if _xvb_real_tor_fetch; then
        ok "XvB stats request reached the real endpoint through the guest Tor SOCKS only"
    else
        bad "XvB stats request did not complete through the guest Tor SOCKS only"
        return
    fi
    _ssh "podman start xmrig-proxy >/dev/null" || {
        bad "held xmrig-proxy could not start for the bounded XvB actuator injection"
        return
    }
    # shellcheck disable=SC2154 # status is set by the EXIT trap when it runs.
    trap 'status=$?; _ssh "podman stop -t 5 xmrig-proxy >/dev/null 2>&1" || true; exit "$status"' EXIT
    pools="$(_xvb_guest_python "$(_xvb_payload XVB)" 2>/dev/null)"
    if [ -z "$pools" ]; then
        bad "controller actuator could not switch the live proxy to XvB"
        return
    fi
    if printf '%s' "$pools" | jq -e '.mode == "XVB" and .pools[0].enabled == true and .pools[0].tor and .pools[1].enabled == false' >/dev/null; then
        ok "bounded controller injection moved the live proxy to Tor-routed XvB"
    else
        bad "bounded controller injection did not leave XvB as the live Tor-routed proxy route"
        rc=1
    fi
    pools="$(_xvb_guest_python "$(_xvb_payload P2POOL)" 2>/dev/null)"
    if [ -z "$pools" ]; then
        bad "controller actuator could not restore the live proxy to P2Pool"
        return
    fi
    if printf '%s' "$pools" | jq -e '.mode == "P2POOL" and .pools[0].enabled == true and (.pools[0].tor | not) and .pools[1].enabled == false' >/dev/null; then
        ok "bounded controller injection restored the live proxy to P2Pool"
    else
        bad "bounded controller injection did not restore P2Pool as the live proxy route"
        rc=1
    fi
    return "$rc"
)

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
    payload="$(_xvb_payload XVB)"
    [ -n "$payload" ] && [ -n "$(_xvb_payload P2POOL)" ] &&
        printf '%s' "$payload" | base64 -d | grep -q 'XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN)' &&
        ! _xvb_payload SPLIT >/dev/null || exit 1
    echo "appliance-xvb-routing-leg self-test passed"
fi
