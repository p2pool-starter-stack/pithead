# shellcheck shell=bash
# Shared fixture/live verdict for the dashboard's appliance listener boundary (#2070).

DASHBOARD_TEST_GLOBAL_V6="2001:db8:2070::1"
DASHBOARD_TEST_FALLBACK_ULA="fd00:2070::1"

# Shared by every live-listener verdict below: scans `ss -Hltnp` rows for a caddy socket bound to a
# wildcard (echoes why and fails) or, when <extra-addr> is given, to that address too.
_dashboard_reject_wildcard_or_extra_listener() { # <ss> [extra-addr]
    local sockets="$1" extra="${2:-}" line local_addr
    while IFS= read -r line; do
        case "$line" in *caddy*) ;; *) continue ;; esac
        local_addr=$(awk '{print $4}' <<<"$line")
        case "$local_addr" in
        \*:* | 0.0.0.0:* | "[::]":* | :::*)
            echo "Caddy owns a wildcard listener"
            return 1
            ;;
        esac
        [ -z "$extra" ] || case "$local_addr" in "$extra":* | "[$extra]":*)
            echo "Caddy listens on the global address ($extra)"
            return 1
            ;;
        esac
    done <<<"$sockets"
}

dashboard_exposure_verdict() { # <Caddyfile> <ss> <curl-rc> <doctor-json> <lan-v4> <ula-v6> <global-v6> <pinned-site>
    local caddy="$1" sockets="$2" curl_rc="$3" doctor="$4" lan="$5" ula="$6" global="$7" site="$8" binds reason
    case "$caddy" in *"$global"*)
        echo "Caddyfile publishes the global address ($global)"
        return 1
        ;;
    esac
    case "$caddy" in *"https://$site"*) ;; *)
        echo "Caddyfile site list omits the pinned host ($site)"
        return 1
        ;;
    esac
    if ! reason=$(_dashboard_reject_wildcard_or_extra_listener "$sockets" "$global"); then
        echo "$reason"
        return 1
    fi
    for endpoint in "$lan:443" "[$ula]:443"; do
        printf '%s\n' "$sockets" | grep -F " $endpoint " | grep -q caddy || {
            echo "Caddy is not listening on $endpoint"
            return 1
        }
    done
    binds=$(printf '%s\n' "$caddy" | grep '^    bind ' || true)
    for address in "$lan" "$ula"; do
        case " $binds " in *" $address "*) ;; *)
            echo "Caddyfile bind lines omit $address"
            return 1
            ;;
        esac
    done
    case "$binds" in *"$global"*)
        echo "Caddyfile binds the global address ($global)"
        return 1
        ;;
    esac
    [ "$curl_rc" != 0 ] || {
        echo "the dashboard answered on the global address ($global)"
        return 1
    }
    printf '%s' "$doctor" | jq -e 'any(.checks[]?; .status == "ok" and .message == "Dashboard listener excludes every public host address.")' >/dev/null 2>&1 || {
        echo "doctor did not report the dashboard public-listener check OK"
        return 1
    }
    echo "dashboard keeps the pinned site and excludes the guest's global v6 from its binds and live listeners; LAN v4 and ULA remain served, the global curl is refused, and doctor agrees"
}

stage_dashboard_exposure_addresses() {
    local iface ula
    # shellcheck disable=SC2154 # set by tests/os/lib/core.sh after the guest gets DHCP.
    iface=$(_ssh "ip -o -4 addr show | awk -v a='$ip/' 'index(\$4,a)==1 {print \$2; exit}'" | tr -d '\r\n')
    [ -n "$iface" ] || {
        bad "could not identify the guest LAN interface for the dashboard exposure row"
        return 1
    }
    ula=$(_ssh "ip -6 -o addr show dev '$iface' | awk '{sub(/\\/.*/,\"\",\$4); if (\$4 ~ /^[fF][cCdD]/) {print \$4; exit}}'" | tr -d '\r\n')
    if [ -n "$ula" ]; then
        _ssh "ip -6 addr replace '$DASHBOARD_TEST_GLOBAL_V6/128' dev '$iface' nodad"
    else
        ula="$DASHBOARD_TEST_FALLBACK_ULA"
        _ssh "ip -6 addr replace '$DASHBOARD_TEST_GLOBAL_V6/128' dev '$iface' nodad && ip -6 addr replace '$ula/128' dev '$iface' nodad"
    fi || {
        bad "could not stage documentation-range global v6 + ULA on the guest LAN interface"
        return 1
    }
    DASHBOARD_TEST_LAN_V4="$ip"
    DASHBOARD_TEST_ULA_V6="$ula"
    ok "guest LAN interface carries a documentation-range global v6 and a ULA"
}

phase_provision_dashboard_exposure() {
    local caddy sockets curl_rc=1 doctor verdict
    caddy=$(_ssh "cat /data/pithead/Caddyfile" 2>/dev/null) || caddy=""
    sockets=$(_ssh "ss -Hltnp" 2>/dev/null) || sockets=""
    if _ssh "curl -ksS --connect-timeout 3 -m 5 -o /dev/null 'https://[$DASHBOARD_TEST_GLOBAL_V6]/'" >/dev/null 2>&1 ||
        _ssh "curl -sS --connect-timeout 3 -m 5 -o /dev/null 'http://[$DASHBOARD_TEST_GLOBAL_V6]/'" >/dev/null 2>&1; then
        curl_rc=0
    fi
    doctor=$(_ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json" 2>/dev/null) || true
    if verdict=$(dashboard_exposure_verdict "$caddy" "$sockets" "$curl_rc" "$doctor" \
        "$DASHBOARD_TEST_LAN_V4" "$DASHBOARD_TEST_ULA_V6" "$DASHBOARD_TEST_GLOBAL_V6" "$PROVISION_DASHBOARD_HOST"); then
        ok "$verdict"
    else
        bad "$verdict"
        return 1
    fi
}

# #2280: the exposure boundary above never turns the onion on, so a wildcard/public socket that
# ONLY appears once the dashboard is republished as a Tor hidden service (tor+caddy recreate) would
# ship unseen. Onion vhosts bind the container-bridge gateway by design (35-caddyfile-and-auth-
# helpers.sh's _onion_bind_line) — this proves that design holds on a live, provisioned box, not
# just in the sourced-function unit render.
dashboard_onion_exposure_verdict() { # <Caddyfile> <ss> <doctor-json> <bridge-gateway>
    local caddy="$1" sockets="$2" doctor="$3" gw="$4" reason
    case "$caddy" in *"http://$gw {"*) ;; *)
        echo "Caddyfile has no onion vhost bound to the bridge gateway ($gw)"
        return 1
        ;;
    esac
    if ! reason=$(_dashboard_reject_wildcard_or_extra_listener "$sockets"); then
        echo "$reason (with the onion enabled)"
        return 1
    fi
    printf '%s\n' "$sockets" | grep -F " $gw:80 " | grep -q caddy || {
        echo "Caddy is not listening on the onion bridge gateway ($gw:80)"
        return 1
    }
    printf '%s' "$doctor" | jq -e 'any(.checks[]?; .status == "ok" and .message == "Dashboard listener excludes every public host address.")' >/dev/null 2>&1 || {
        echo "doctor did not report the dashboard public-listener check OK with the onion enabled"
        return 1
    }
    echo "onion-enabled appliance keeps Caddy's listeners private: the onion vhost binds the bridge gateway, no wildcard socket appears, and doctor agrees"
}

dashboard_onion_state_verdict() {
    printf '%s' "$1" | jq -e --arg onion "$2" '
        .dashboard_onion.url == ("http://" + $onion) and
        .dashboard_onion.client_auth == true' >/dev/null 2>&1
}

dashboard_onion_key_verdict() {
    printf '%s' "$1" | jq -e --arg onion "$2" '
        .status == "applied" and
        (.id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
        .onion_url == ("http://" + $onion) and
        (.client_key | type == "string" and test("^[A-Z2-7]{52}$")) and
        .torrc_line == (($onion | sub("\\.onion$"; "")) + ":descriptor:x25519:" + .client_key)' >/dev/null 2>&1
}

dashboard_onion_state_evidence() {
    printf '%s' "$1" | jq -Rsc --arg http "$2" --argjson curl "$3" --arg onion "$4" '
        (try fromjson catch null) as $d |
        {http:$http, curl:$curl, json:($d | type == "object"),
         onion_present:(try ($d.dashboard_onion | type == "object") catch false),
         url_matches:(try ($d.dashboard_onion.url == ("http://" + $onion)) catch false),
         client_auth:(try ($d.dashboard_onion.client_auth == true) catch false)}' 2>/dev/null
}

phase_provision_dashboard_onion_control() {
    local onion state result rid n response http=none crc=0
    n=0
    while [ "$n" -lt 20 ]; do
        onion=$(_ssh 'set -eu
cd /data/pithead
onion=$(podman exec tor cat /var/lib/tor/dashboard/hostname)
test "$onion" = "$(sed -n "s/^DASHBOARD_ONION_ADDRESS=//p" .env)"
printf "%s" "$onion"' 2>/dev/null) || onion=""
        onion=$(printf '%s' "$onion" | tr -d '\r\n')
        [[ $onion =~ ^[a-z2-7]{56}\.onion$ ]] && break
        n=$((n + 1))
        sleep 3
    done
    if [ "$n" -eq 20 ]; then
        bad "dashboard onion address does not match Tor hostname and rendered environment (#3074)"
        return 1
    fi
    ok "dashboard onion address matches Tor hostname and rendered environment (#3074)"
    n=0
    while [ "$n" -lt 20 ]; do
        crc=0
        response=$(dashboard_curl -sSk -m 8 -w '\n%{http_code}' "https://$ip/api/state" 2>/dev/null) || crc=$?
        http=${response##*$'\n'}
        if [[ $http =~ ^[0-9]{3}$ ]]; then
            state=${response%$'\n'*}
        else
            http=none state=""
        fi
        if [ "$crc" -eq 0 ] && [ "$http" = 200 ] && dashboard_onion_state_verdict "$state" "$onion"; then
            break
        fi
        n=$((n + 1))
        sleep 3
    done
    if [ "$n" -eq 20 ]; then
        bad "dashboard header state did not publish the provisioned client-authorized onion (#3074)"
        dashboard_onion_state_evidence "$state" "$http" "$crc" "$onion"
        _ssh "set -euo pipefail
podman inspect dashboard --format '{{json .Config.Env}}' | jq -ce --arg onion '$onion' '
            {runtime_enabled:(index(\"DASHBOARD_ONION_ENABLED=true\") != null),
             runtime_address_matches:(index(\"DASHBOARD_ONION_ADDRESS=\" + \$onion) != null),
             runtime_client_auth:(index(\"DASHBOARD_ONION_CLIENT_AUTH=true\") != null)}'" 2>/dev/null ||
            printf '%s\n' 'dashboard onion runtime evidence unavailable'
        return 1
    fi
    ok "dashboard header state publishes the provisioned client-authorized onion (#3074)"
    result=$(dashboard_control_request onion-client-key '{}') || result=""
    if ! dashboard_onion_key_verdict "$result" "$onion"; then
        result=""
        bad "Show client key did not return both coherent key forms through the appliance control route (#3074)"
        return 1
    fi
    rid=$(printf '%s' "$result" | jq -r .id)
    result=""
    ok "Show client key returns both key forms for the provisioned onion (#3074)"
    n=0
    while [ "$n" -lt 6 ]; do
        if _ssh "jq -es --arg id '$rid' 'any(.[]; .id == \$id and .action == \"onion-client-key\" and .status == \"applied\")' /data/pithead/data/control/audit/control.log >/dev/null" 2>/dev/null; then
            break
        fi
        n=$((n + 1))
        sleep 1
    done
    if [ "$n" -lt 6 ]; then
        ok "Show client key records an applied audit row for its request (#3074)"
    else
        bad "Show client key has no applied audit row for its request (#3074)"
    fi
    n=0
    while [ "$n" -lt 12 ]; do
        if _ssh "jq -e '.status == \"applied\" and has(\"client_key\") and has(\"torrc_line\") and .client_key == null and .torrc_line == null and .onion_url == \"http://$onion\"' /data/pithead/data/control/results/$rid.json >/dev/null" 2>/dev/null; then
            ok "Show client key host result redacts both secret forms after its timer (#3074)"
            return 0
        fi
        n=$((n + 1))
        sleep 5
    done
    bad "Show client key host result retained a secret or became unreadable after 60 seconds (#3074)"
    return 1
}

# Host-side apply provisions the fixture before exercising the dashboard control route.
phase_provision_dashboard_onion_exposure() {
    # shellcheck disable=SC2034
    local DASH_USER="$1" DASH_PASS="$2"
    local caddy sockets doctor prefix gw verdict apply_out
    # Before the snapshot, so a spool that never drains leaves the guest exactly as it was found.
    # Apply does not stop a running runner (#2363); this is the harness's phase boundary.
    _control_requests_drained || {
        bad "onion exposure: the control spool never drained — refusing to cross the harness phase boundary"
        return
    }
    approval_capture_restore_snapshot || {
        bad "onion exposure: could not snapshot the guest's config.json"
        return
    }
    if ! apply_out=$(_ssh 'set -eu
cd /data/pithead
jq -c ".dashboard.onion.enabled = true | .dashboard.onion.client_auth = true" config.json >config.json.onion-test
mv config.json.onion-test config.json
./pithead apply -y' 2>&1); then
        bad "onion exposure: ./pithead apply -y did not accept the onion-enabled config"
        # #2680: apply's own reason, then tor's own account of it, read before the cleanup apply
        # below recreates tor. Job 1000's only evidence was compose's "container tor is unhealthy".
        printf '%s\n' "$apply_out" | tail -n 20 | tr -d '\r' | sed 's/^/     | /'
        tor_health_evidence
        approval_restore_pending || bad "onion exposure: cleanup after a failed apply also failed"
        return
    fi
    ok "dashboard Tor onion fixture enabled with client authorization via host-side apply"

    prefix=$(_ssh "grep '^NETWORK_PREFIX=' /data/pithead/.env | cut -d= -f2" | tr -d '\r\n')
    if [ -z "$prefix" ]; then
        bad "onion exposure: could not read NETWORK_PREFIX from the guest's .env"
    else
        gw="${prefix}.1"
        caddy=$(_ssh "cat /data/pithead/Caddyfile" 2>/dev/null) || caddy=""
        sockets=$(_ssh "ss -Hltnp" 2>/dev/null) || sockets=""
        doctor=$(_ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json" 2>/dev/null) || true
        if verdict=$(dashboard_onion_exposure_verdict "$caddy" "$sockets" "$doctor" "$gw"); then
            ok "$verdict"
        else
            bad "$verdict"
        fi
    fi

    phase_provision_dashboard_onion_control || bad "dashboard onion control acceptance did not complete (#3074)"

    approval_restore_pending || bad "onion-enable cleanup (restoring the original config) failed"
}
