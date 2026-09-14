# shellcheck shell=bash
# Bounded XvB actuation smoke for the throwaway KVM appliance. The appliance is
# intentionally unsynchronised, so this injects the controller's existing switch
# method rather than pretending a PPLNS share or routed hashrate exists.
[ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ] || : "${OS_RUN_SUITE:?source via the suite runner}"

_xvb_payload() { # <mode> -> base64 Python that calls the real controller actuator
    case "$1" in P2POOL | XVB) ;; *) return 2 ;; esac
    printf '%s\n' "import asyncio" "from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient" \
        "from mining_dashboard.service.storage_service import StateManager" \
        "from mining_dashboard.service.xvb.algo_service import AlgoService" \
        "asyncio.run(AlgoService(StateManager(), XMRigProxyClient(), None).switch_miners('$1'))" |
        base64 | tr -d '\n'
}

_xvb_guest_python() { _ssh "printf %s '$1' | base64 -d | podman exec -i dashboard python3 -"; }

_xvb_proxy_pools() {
    _ssh "podman exec dashboard python3 -c 'import json; from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient; print(json.dumps(XMRigProxyClient().get_config().get(\"pools\", [])))'"
}

_xvb_real_tor_fetch() {
    local payload
    payload="$(base64 <"$SCRIPT_DIR/../integration/lib/xvb-egress-probe.py" | tr -d '\n')"
    _xvb_guest_python "$payload"
}

phase_provision_xvb_routing() { # <dashboard user> <dashboard password>
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
    trap '_ssh "podman stop -t 5 xmrig-proxy >/dev/null 2>&1" || true' RETURN
    if ! _xvb_guest_python "$(_xvb_payload XVB)"; then
        bad "controller actuator could not switch the live proxy to XvB"
        return
    fi
    pools="$(_xvb_proxy_pools 2>/dev/null)"
    if printf '%s' "$pools" | jq -e '.[0].enabled == true and (.[0].socks5 | endswith(":9050")) and .[1].enabled == false' >/dev/null; then
        ok "bounded controller injection moved the live proxy to Tor-routed XvB"
    else
        bad "bounded controller injection did not leave XvB as the live Tor-routed proxy route"
        rc=1
    fi
    # shellcheck disable=SC2154 # provision owns the guest IP.
    state="$(dashboard_curl -sSk -m 8 "https://$ip/api/state" 2>/dev/null)"
    if printf '%s' "$state" | jq -e '.hashrate.mode_name | startswith("XVB")' >/dev/null; then
        ok "dashboard exposed the injected XvB route"
    else
        bad "dashboard did not expose the injected XvB route"
        rc=1
    fi
    if ! _xvb_guest_python "$(_xvb_payload P2POOL)"; then
        bad "controller actuator could not restore the live proxy to P2Pool"
        return
    fi
    pools="$(_xvb_proxy_pools 2>/dev/null)"
    if printf '%s' "$pools" | jq -e '.[0].enabled == true and (.[0] | has("socks5") | not) and .[1].enabled == false' >/dev/null; then
        ok "bounded controller injection restored the live proxy to P2Pool"
    else
        bad "bounded controller injection did not restore P2Pool as the live proxy route"
        rc=1
    fi
    return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
    OS_RUN_SUITE=1
    [ -n "$(_xvb_payload XVB)" ] && [ -n "$(_xvb_payload P2POOL)" ] && ! _xvb_payload SPLIT >/dev/null || exit 1
    echo "appliance-xvb-routing-leg self-test passed"
fi
