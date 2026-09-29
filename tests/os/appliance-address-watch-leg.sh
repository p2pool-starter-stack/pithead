# shellcheck shell=bash
# The address watch (#2463): an IPv6 address acquired after provisioning must reach the dashboard
# certificate without an apply or a reboot.

ADDRESS_WATCH_TEST_ULA="fd00:2463::1"
# openssl prints an IPv6 SAN fully expanded and upper-case.
ADDRESS_WATCH_TEST_ULA_SAN="IP Address:FD00:2463:0:0:0:0:0:1"
ADDRESS_WATCH_COVERED_OK="The dashboard certificate covers every name Caddy serves."

address_watch_verdict() { # <timer-enabled> <timer-active> <doctor-json> <service-result> <cert-sans> <address> <san-entry>
    local enabled="$1" active="$2" doctor="$3" result="$4" sans="$5" addr="$6" san="$7"
    [ "$enabled" = enabled ] || {
        echo "pithead-address-watch.timer is not enabled (systemctl is-enabled: ${enabled:-empty})"
        return 1
    }
    [ "$active" = active ] || {
        echo "pithead-address-watch.timer is not active (systemctl is-active: ${active:-empty})"
        return 1
    }
    [ "$result" = 0 ] || {
        echo "pithead-address-watch.service did not run to success (exit $result)"
        return 1
    }
    case "$sans" in *"$san"*) ;; *)
        echo "the dashboard certificate does not carry the added address ($addr)"
        return 1
        ;;
    esac
    printf '%s' "$doctor" | jq -e --arg m "$ADDRESS_WATCH_COVERED_OK" 'any(.checks[]?; .status == "ok" and .message == $m)' >/dev/null 2>&1 || {
        echo "doctor's certificate row is not green after the address watch ran"
        return 1
    }
    echo "the address watch timer is enabled and active, and one service run re-minted the certificate for an address added after provisioning; doctor's certificate row is green"
}

phase_provision_address_watch() {
    local iface enabled active doctor rc sans verdict
    # shellcheck disable=SC2154 # $ip is set by tests/os/lib/core.sh after the guest gets DHCP.
    iface=$(_ssh "ip -o -4 addr show | awk -v a='$ip/' 'index(\$4,a)==1 {print \$2; exit}'" | tr -d '\r\n')
    [ -n "$iface" ] || {
        bad "address watch: could not identify the guest LAN interface"
        return 1
    }
    _ssh "ip -6 addr replace '$ADDRESS_WATCH_TEST_ULA/64' dev '$iface' nodad" || {
        bad "address watch: could not add a ULA to the guest after provisioning"
        return 1
    }
    # Informational: the row that used to stay red for the life of the box.
    doctor=$(_ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json" 2>/dev/null) || true
    printf '%s' "$doctor" | jq -r '.checks[]? | select(.message | startswith("The dashboard certificate does not cover")) | .message' 2>/dev/null |
        sed 's/^/     before the watch: /'
    enabled=$(_ssh "systemctl is-enabled pithead-address-watch.timer" 2>/dev/null | tr -d '\r\n') || true
    active=$(_ssh "systemctl is-active pithead-address-watch.timer" 2>/dev/null | tr -d '\r\n') || true
    _ssh "systemctl start pithead-address-watch.service" >/dev/null 2>&1
    rc=$?
    # Caddy restarts inside the service run; give the listener and doctor a moment to settle.
    sleep 10
    sans=$(_ssh "openssl x509 -in /data/pithead/data/tls/wizard.crt -noout -ext subjectAltName" 2>/dev/null) || sans=""
    sans=${sans//$'\n'/ }
    for _ in 1 2 3 4; do
        doctor=$(_ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json" 2>/dev/null) || true
        printf '%s' "$doctor" | jq -e --arg m "$ADDRESS_WATCH_COVERED_OK" 'any(.checks[]?; .status == "ok" and .message == $m)' >/dev/null 2>&1 && break
        sleep 15
    done
    if verdict=$(address_watch_verdict "$enabled" "$active" "$doctor" "$rc" "$sans" "$ADDRESS_WATCH_TEST_ULA" "$ADDRESS_WATCH_TEST_ULA_SAN"); then
        ok "$verdict"
    else
        bad "$verdict"
        printf '%s' "$doctor" | jq -r '.checks[]? | select(.message | test("certificate")) | "\(.status): \(.message)"' 2>/dev/null | sed 's/^/     doctor: /'
        _ssh "journalctl -u pithead-address-watch.service --no-pager -n 20" 2>/dev/null | tr -d '\r' | sed 's/^/     | /'
        return 1
    fi
}
