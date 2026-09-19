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

_xvb_route_is() { # <route-json> <mode> <tor-routed: true|false>
    printf '%s' "$1" | jq -e --arg mode "$2" --argjson tor "$3" \
        '.mode == $mode and .pools[0].enabled == true and .pools[0].tor == $tor and .pools[1].enabled == false' \
        >/dev/null 2>&1
}

# Both directions of the transition this issue exists to observe. Every red row returns 1 on the
# spot; the caller puts the guest back either way, so an early return cannot strand the proxy.
_xvb_routing_actuation() {
    local pools
    pools="$(_xvb_guest_python "$(_xvb_payload XVB)" 2>/dev/null)"
    if [ -z "$pools" ]; then
        bad "controller actuator could not switch the live proxy to XvB"
        return 1
    fi
    if ! _xvb_route_is "$pools" XVB true; then
        bad "bounded controller injection did not leave XvB as the live Tor-routed proxy route"
        return 1
    fi
    ok "bounded controller injection moved the live proxy to Tor-routed XvB"
    pools="$(_xvb_guest_python "$(_xvb_payload P2POOL)" 2>/dev/null)"
    if [ -z "$pools" ]; then
        bad "controller actuator could not restore the live proxy to P2Pool"
        return 1
    fi
    if ! _xvb_route_is "$pools" P2POOL false; then
        bad "bounded controller injection did not restore P2Pool as the live proxy route"
        return 1
    fi
    ok "bounded controller injection restored the live proxy to P2Pool"
}

# NOT a subshell body: ok/bad must count in the harness's own PASS/FAIL, and a bare `return` after
# bad() returns printf's 0 — between them a red leg read as a clean one and the caller never saw it.
phase_provision_xvb_routing() {
    local rc=0
    info "provision leg — bounded XvB routing injection"
    if _xvb_real_tor_fetch; then
        ok "XvB stats request reached the real endpoint through the guest Tor SOCKS only"
    else
        bad "XvB stats request did not complete through the guest Tor SOCKS only"
        return 1
    fi
    _ssh "podman start xmrig-proxy >/dev/null" || {
        bad "held xmrig-proxy could not start for the bounded XvB actuator injection"
        return 1
    }
    _xvb_routing_actuation || rc=1
    # Put the guest back the way the fresh appliance holds it (#35): re-assert P2POOL when the
    # actuation bailed mid-transition, so the fourteen rows after this one do not run against a
    # dashboard still persisting XVB, then stop the proxy again.
    [ "$rc" -eq 0 ] || _xvb_guest_python "$(_xvb_payload P2POOL)" >/dev/null 2>&1 || true
    _ssh "podman stop -t 5 xmrig-proxy >/dev/null 2>&1" || true
    return "$rc"
}

_xvb_self_test() {
    local f=0 payload
    payload="$(_xvb_payload XVB)"
    [ -n "$payload" ] && [ -n "$(_xvb_payload P2POOL)" ] &&
        printf '%s' "$payload" | base64 -d | grep -q 'XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN)' &&
        ! _xvb_payload SPLIT >/dev/null || {
        printf 'xvb self-test: actuator payload shape\n' >&2
        f=$((f + 1))
    }

    # Drive the REAL leg, one inverted assertion at a time. A source grep would pass on a leg whose
    # rows never reach the harness's counters, which is exactly the defect this replaced: the rows
    # must be counted HERE, in the caller's own PASS/FAIL, and the leg must return non-zero.
    local PASS=0 FAIL=0 XVBT_FETCH_RC=0 XVBT_START_RC=0 XVBT_XVB_JSON="" XVBT_P2P_JSON=""
    local xvb_ok='{"mode":"XVB","pools":[{"enabled":true,"tor":true},{"enabled":false,"tor":false}]}'
    local p2p_ok='{"mode":"P2POOL","pools":[{"enabled":true,"tor":false},{"enabled":false,"tor":false}]}'
    ok() { PASS=$((PASS + 1)); }
    bad() { FAIL=$((FAIL + 1)); }
    info() { :; }
    _ssh() {
        case "$1" in *"podman start"*) return "$XVBT_START_RC" ;; esac
        return 0
    }
    _xvb_real_tor_fetch() { return "$XVBT_FETCH_RC"; }
    _xvb_guest_python() { # answers the mode the leg actually asked the guest to switch to
        case "$(printf '%s' "$1" | base64 -d 2>/dev/null)" in
        *"switch_miners('XVB')"*) printf '%s' "$XVBT_XVB_JSON" ;;
        *"switch_miners('P2POOL')"*) printf '%s' "$XVBT_P2P_JSON" ;;
        esac
    }
    _xvb_case() { # <label> <want-pass> <want-fail> <want-rc>
        local rc=0
        PASS=0 FAIL=0
        phase_provision_xvb_routing >/dev/null 2>&1 || rc=$?
        [ "$PASS" = "$2" ] && [ "$FAIL" = "$3" ] && [ "$rc" = "$4" ] || {
            printf 'xvb self-test: %s — pass=%s want %s, fail=%s want %s, rc=%s want %s\n' \
                "$1" "$PASS" "$2" "$FAIL" "$3" "$rc" "$4" >&2
            f=$((f + 1))
        }
    }

    XVBT_XVB_JSON="$xvb_ok" XVBT_P2P_JSON="$p2p_ok"
    _xvb_case "a clean transition reports three green rows and rc 0" 3 0 0

    XVBT_FETCH_RC=1
    _xvb_case "an unreachable real XvB request over guest Tor is a counted red row" 0 1 1
    XVBT_FETCH_RC=0

    XVBT_START_RC=1
    _xvb_case "a held xmrig-proxy that will not start is a counted red row" 1 1 1
    XVBT_START_RC=0

    # #2321's own row: the actuator answering nothing must be RED and must reach the summary.
    XVBT_XVB_JSON=""
    _xvb_case "an actuator that cannot switch the live proxy to XvB is a counted red row" 1 1 1

    XVBT_XVB_JSON='{"mode":"P2POOL","pools":[{"enabled":true,"tor":true},{"enabled":false,"tor":false}]}'
    _xvb_case "a dashboard left persisting P2POOL after the XvB switch is a counted red row" 1 1 1

    XVBT_XVB_JSON='{"mode":"XVB","pools":[{"enabled":true,"tor":false},{"enabled":false,"tor":false}]}'
    _xvb_case "an XvB route that is not Tor-routed is a counted red row" 1 1 1

    XVBT_XVB_JSON='{"mode":"XVB","pools":[{"enabled":true,"tor":true},{"enabled":true,"tor":false}]}'
    _xvb_case "a second pool left enabled beside XvB is a counted red row" 1 1 1

    XVBT_XVB_JSON='{"mode":"XVB","pools":[{"enabled":false,"tor":true},{"enabled":false,"tor":false}]}'
    _xvb_case "an XvB route whose own pool is disabled is a counted red row" 1 1 1
    XVBT_XVB_JSON="$xvb_ok"

    XVBT_P2P_JSON=""
    _xvb_case "an actuator that cannot restore P2Pool is a counted red row" 2 1 1

    XVBT_P2P_JSON='{"mode":"XVB","pools":[{"enabled":true,"tor":false},{"enabled":false,"tor":false}]}'
    _xvb_case "a dashboard left persisting XVB after the restore is a counted red row" 2 1 1

    XVBT_P2P_JSON='{"mode":"P2POOL","pools":[{"enabled":true,"tor":true},{"enabled":false,"tor":false}]}'
    _xvb_case "a P2Pool route left Tor-routed is a counted red row" 2 1 1

    XVBT_P2P_JSON='{"mode":"P2POOL","pools":[{"enabled":false,"tor":false},{"enabled":false,"tor":false}]}'
    _xvb_case "a restored P2Pool route whose own pool is disabled is a counted red row" 2 1 1

    unset -f ok bad info _ssh _xvb_real_tor_fetch _xvb_guest_python _xvb_case
    [ "$f" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
    _xvb_self_test || exit 1
    echo "appliance-xvb-routing-leg self-test passed"
fi
