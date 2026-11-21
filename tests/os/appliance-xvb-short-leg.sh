# shellcheck shell=bash
# shellcheck disable=SC2154
# One bounded XvB-on leg for the stack guest, built on the routing and config-approval legs' helpers.

_XVB_SHORT_OFF='P2POOL (XvB Disabled)'
_XVB_SHORT_ROUTED=0

_xvb_short_state() { # prints "<mode name><TAB><fetch fail count>", nothing when unreadable
    _ssh 'curl -fsS --max-time 10 http://127.0.0.1:8000/api/state' 2>/dev/null |
        jq -r '[(.hashrate.mode_name // ""), (.hashrate.xvb_fail_count // 0)] | @tsv' 2>/dev/null
}

_xvb_short_state_is() { # <on|off> <state line>
    local mode="${2%%$'\t'*}" fails="${2##*$'\t'}"
    case "$1:$mode" in
    off:"$_XVB_SHORT_OFF") return 0 ;;
    off:* | on:*Disabled* | on:) return 1 ;;
    on:*) [ "$fails" = 0 ] ;;
    esac
}

_xvb_short_wait() { # <on|off> -> 0 once the dashboard reads that state, else prints the last read
    local state="" deadline
    deadline=$(($(date +%s) + ${XVB_SHORT_STATE_TIMEOUT:-180}))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        state="$(_xvb_short_state)"
        _xvb_short_state_is "$1" "$state" && return 0
        sleep 3
    done
    printf '%s' "${state:-unreadable}" | tr '\t' ' '
    return 1
}

_xvb_short_route_payload() {
    printf '%s\n' "import json" \
        "from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient" \
        "from mining_dashboard.config.config import PROXY_API_PORT, PROXY_AUTH_TOKEN, PROXY_HOST, XVB_DONOR_ID, XVB_POOL_URL" \
        "pools = XMRigProxyClient(PROXY_HOST, PROXY_API_PORT, PROXY_AUTH_TOKEN).get_config().get('pools', [])" \
        "print(json.dumps({'xvb_url': XVB_POOL_URL, 'donor': XVB_DONOR_ID, 'pools': [{'url': p.get('url'), 'user': p.get('user'), 'enabled': p.get('enabled'), 'tor': bool(p.get('socks5'))} for p in pools]}))" |
        base64 | tr -d '\n'
}

_xvb_short_route_ok() { # <route json> <wallet>: the one enabled pool is XvB, over Tor, as the wallet's donor id
    printf '%s' "$1" | jq -e --arg w "$2" '
        .donor as $d | .xvb_url as $u |
        ($d | length) >= 8 and ($w | startswith($d)) and
        ([.pools[] | select(.enabled)] | length == 1 and .[0].url == $u and .[0].user == $d and .[0].tor == true)' \
        >/dev/null 2>&1
}

_xvb_short_no_route() { # prints the reason and returns 0 when the guest cannot reach XvB
    local status
    if ! status="$(_xvb_wait_for_tor)"; then
        printf 'guest Tor never bootstrapped (last health: %s), so XvB is unreachable' "$status"
        return 0
    fi
    ! _xvb_real_tor_fetch_retry || return 1
    printf 'XvB endpoint unreachable through the guest Tor SOCKS'
}

_xvb_short_set_on() {
    SSH_TIMEOUT=480 _ssh 'set -eu
cd /data/pithead
jq -c ".xvb.enabled = true" config.json >config.json.xvb-short
mv config.json.xvb-short config.json
./pithead apply -y' >/dev/null 2>&1
}

_xvb_short_prove() {
    local state route
    if ! _xvb_short_set_on; then
        bad "XvB leg: xvb.enabled=true through ./pithead apply -y was refused"
        return 1
    fi
    if ! state="$(_xvb_short_wait on)"; then
        bad "XvB leg: dashboard never showed XvB active with no fetch error within ${XVB_SHORT_STATE_TIMEOUT:-180}s (last: $state)"
        return 1
    fi
    ok "XvB leg: dashboard state shows XvB active with no fetch error"
    if ! _xvb_wait_for_proxy_api; then
        bad "XvB leg: xmrig-proxy API never answered within ${XVB_PROXY_READY_TIMEOUT:-150}s $(_xvb_proxy_diag)"
        return 1
    fi
    _XVB_SHORT_ROUTED=1
    if ! _xvb_actuate XVB true >/dev/null; then
        bad "XvB leg: the controller could not route the live proxy to XvB within ${XVB_ACTUATE_TIMEOUT:-150}s (guest: $(_xvb_guest_stderr))"
        return 1
    fi
    route="$(_xvb_guest_python "$(_xvb_short_route_payload)")"
    if ! _xvb_short_route_ok "$route" "$HARNESS_WALLET"; then
        bad "XvB leg: the live proxy route is not the XvB pool over Tor under the stack wallet's donor id (guest: $(_xvb_guest_stderr))"
        return 1
    fi
    ok "XvB leg: the live proxy routes to the XvB pool over Tor under the stack wallet's donor id"
    state="$(_xvb_short_state)"
    if ! _xvb_short_state_is on "$state"; then
        bad "XvB leg: dashboard reported an XvB error after routing (state: $(printf '%s' "$state" | tr '\t' ' '))"
        return 1
    fi
}

_xvb_short_restore() {
    local rc=0 state
    if [ "$_XVB_SHORT_ROUTED" = 1 ] && ! _xvb_actuate P2POOL false >/dev/null; then
        bad "XvB leg: the proxy was left on XvB, the P2Pool restore did not confirm (guest: $(_xvb_guest_stderr))"
        rc=1
    fi
    if ! approval_restore_pending; then
        bad "XvB leg: restoring the original config failed, XvB may be left on"
        return 1
    fi
    if state="$(_xvb_short_wait off)"; then
        ok "XvB leg: XvB is off again"
    else
        bad "XvB leg: dashboard never read XvB off after the restore (last: $state)"
        rc=1
    fi
    return "$rc"
}

phase_stack_xvb_short() {
    local state reason rc=0
    info "stack leg — short XvB-on proof; XvB is off for the rest of the battery"
    if ! state="$(_xvb_short_wait off)"; then
        bad "XvB leg: XvB is not off by default on the stack guest (dashboard: $state)"
        return 1
    fi
    ok "XvB leg: XvB is off by default on the stack guest"
    if reason="$(_xvb_short_no_route)"; then
        it_skip_leg "short XvB-on proof" "$reason" missing
        return 0
    fi
    if ! approval_capture_restore_snapshot; then
        bad "XvB leg: could not snapshot the guest's config.json"
        return 1
    fi
    _XVB_SHORT_ROUTED=0
    _xvb_short_prove || rc=1
    _xvb_short_restore || rc=1
    return "$rc"
}
