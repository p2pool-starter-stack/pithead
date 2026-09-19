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

# dashboard.onion.enabled is a setup-time-only field: it names no row in ANY of 42-control-policy-
# and-host-checks.sh's three committable-key tiers, so the dashboard's own control-commit API
# refuses to change it at all ("this change alters a security-sensitive setting ... that is not
# committable from the dashboard ... use 'Set up again' if you need to change it" — measured
# directly: job 428 hit exactly this refusal when this leg first tried the control-commit route).
# "Set up again" itself means a reboot into the wizard, too heavy for one leg — so this toggles it
# the way `apply` (a host command, outside the dashboard's committable-key gate entirely) already
# supports: edit config.json and re-apply, using appliance-config-approval-leg.sh's own
# snapshot/restore pair (approval_capture_restore_snapshot/approval_restore_pending) so the box is
# always left as it was found, whatever the verdict.
phase_provision_dashboard_onion_exposure() {
    local caddy sockets doctor prefix gw verdict
    # Before the snapshot, so a spool that never drains leaves the guest exactly as it was found:
    # this leg's apply restarts the control runner (#2363) and would kill a request in flight
    # (#2094). Nothing here has been captured or edited yet, so the red costs no cleanup.
    _control_requests_drained || {
        bad "onion exposure: the control spool never drained — a host-side apply here would kill a request in flight"
        return
    }
    approval_capture_restore_snapshot || {
        bad "onion exposure: could not snapshot the guest's config.json"
        return
    }
    if ! _ssh 'set -eu
cd /data/pithead
jq -c ".dashboard.onion.enabled = true" config.json >config.json.onion-test
mv config.json.onion-test config.json
./pithead apply -y' >/dev/null 2>&1; then
        bad "onion exposure: ./pithead apply -y did not accept the onion-enabled config"
        approval_restore_pending || bad "onion exposure: cleanup after a failed apply also failed"
        return
    fi
    ok "dashboard Tor onion enabled via a host-side apply (the dashboard's own control-commit route refuses this field by design)"

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

    approval_restore_pending || bad "onion-enable cleanup (restoring the original config) failed"
}
