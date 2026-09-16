# shellcheck shell=bash
# Shared fixture/live verdict for the dashboard's appliance listener boundary (#2070).

DASHBOARD_TEST_GLOBAL_V6="2001:db8:2070::1"
DASHBOARD_TEST_FALLBACK_ULA="fd00:2070::1"

dashboard_exposure_verdict() { # <Caddyfile> <ss> <curl-rc> <doctor-json> <lan-v4> <ula-v6> <global-v6> <pinned-site>
    local caddy="$1" sockets="$2" curl_rc="$3" doctor="$4" lan="$5" ula="$6" global="$7" site="$8" binds line local_addr
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
    while IFS= read -r line; do
        case "$line" in *caddy*) ;; *) continue ;; esac
        local_addr=$(awk '{print $4}' <<<"$line")
        case "$local_addr" in
        "$global":* | "[$global]":*)
            echo "Caddy listens on the global address ($global)"
            return 1
            ;;
        \*:* | 0.0.0.0:* | "[::]":* | :::*)
            echo "Caddy owns a wildcard listener"
            return 1
            ;;
        esac
    done <<<"$sockets"
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
    local caddy="$1" sockets="$2" doctor="$3" gw="$4" line local_addr
    case "$caddy" in *"http://$gw {"*) ;; *)
        echo "Caddyfile has no onion vhost bound to the bridge gateway ($gw)"
        return 1
        ;;
    esac
    while IFS= read -r line; do
        case "$line" in *caddy*) ;; *) continue ;; esac
        local_addr=$(awk '{print $4}' <<<"$line")
        case "$local_addr" in
        \*:* | 0.0.0.0:* | "[::]":* | :::*)
            echo "Caddy owns a wildcard listener with the onion enabled"
            return 1
            ;;
        esac
    done <<<"$sockets"
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

# Enables dashboard.onion.enabled through the SAME approved control-commit path day-two config
# changes use (preview -> reject without APPLY -> commit with APPLY), proving the listener boundary
# survives a real config-driven tor+caddy recreate rather than only a fresh render. Always leaves
# the onion disabled again, whatever the verdict.
phase_provision_dashboard_onion_exposure() { # <dashboard-user> <dashboard-password>
    # shellcheck disable=SC2034  # DASH_USER/DASH_PASS are read by dashboard_curl (provision-browser-submit.sh), a sibling source file shellcheck can't see from here
    local DASH_USER="$1" DASH_PASS="$2" live proposed preview rid result caddy sockets doctor prefix gw verdict
    live=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null) || {
        bad "onion exposure: live config could not be read"
        return
    }
    proposed=$(printf '%s' "$live" | jq -c '.dashboard.onion.enabled = true')
    preview=$(dashboard_control_request preview "$(dashboard_config_body "$proposed")")
    if ! printf '%s' "$preview" | jq -e '.status == "previewed" and .destructive == true and any(.changes[]; .flag == "DEST")' >/dev/null; then
        bad "onion enable did not preview as a destructive/approval-gated change"
        return
    fi
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id}')")
    if ! printf '%s' "$result" | jq -e '.status == "rejected" and (.error | contains("type APPLY"))' >/dev/null; then
        bad "onion enable crossed the approval gate without APPLY"
        return
    fi
    preview=$(dashboard_control_request preview "$(dashboard_config_body "$proposed")")
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY"}')" 300)
    if ! printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null; then
        bad "onion enable did not apply ($(control_result_payload "$result"))"
        return
    fi
    ok "dashboard Tor onion enabled through the approved control-commit path"

    prefix=$(_ssh "grep '^NETWORK_PREFIX=' /data/pithead/.env | cut -d= -f2" | tr -d '\r\n')
    gw="${prefix}.1"
    caddy=$(_ssh "cat /data/pithead/Caddyfile" 2>/dev/null) || caddy=""
    sockets=$(_ssh "ss -Hltnp" 2>/dev/null) || sockets=""
    doctor=$(_ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json" 2>/dev/null) || true
    if verdict=$(dashboard_onion_exposure_verdict "$caddy" "$sockets" "$doctor" "$gw"); then
        ok "$verdict"
    else
        bad "$verdict"
    fi

    proposed=$(dashboard_curl -fsSk -m 8 "https://$ip/api/config" 2>/dev/null | jq -c '.dashboard.onion.enabled = false')
    preview=$(dashboard_control_request preview "$(dashboard_config_body "$proposed")")
    rid=$(printf '%s' "$preview" | jq -r '.id')
    result=$(dashboard_control_request commit "$(jq -nc --arg id "$rid" '{id:$id,confirm:"APPLY"}')" 300)
    printf '%s' "$result" | jq -e '.status == "applied"' >/dev/null || bad "onion-enable cleanup (disabling it again) failed"
}
