# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"

registry_cut_endpoint() {
    local registry="${PITHEAD_REGISTRY:-}" host port
    host="${registry%%/*}"
    case "$host" in
    "" | ghcr.io | ghcr.io:*) return 1 ;;
    esac
    port=443
    case "$host" in *:*) port="${host##*:}" ;; esac
    host="${host%%:*}"
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$port" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "$host" "$port"
}

phase_provision_registry_cut() {
    local endpoint host port
    if ! endpoint=$(registry_cut_endpoint); then
        skip "the registry is cut off before provisioning (#978)" "no private test registry configured to cut"
        return 0
    fi
    read -r host port <<<"$endpoint"
    if _ssh "ip=\$(getent ahostsv4 '$host' | awk 'NR==1{print \$1}'); [ -n \"\$ip\" ] && iptables -I OUTPUT 1 -p tcp -d \"\$ip\" --dport '$port' -m comment --comment pithead-978-registry-cut -j REJECT"; then
        ok "the registry is unreachable from the guest for the whole of provisioning (#978)"
    else
        bad "could not cut the guest off from the registry (#978)"
        return 1
    fi
}

phase_provision_registry_untouched() {
    local hits
    hits=$(_ssh "iptables -L OUTPUT -v -n -x | awk '/pithead-978-registry-cut/ {sum += \$1; seen = 1} END {if (seen) print sum + 0; else print \"missing\"}'" 2>/dev/null | tr -d '\r\n')
    if [ "$hits" = 0 ]; then
        ok "provisioning never tried to reach the registry (#978)"
    else
        bad "provisioning sent ${hits:-unknown} packets at the cut-off registry (#978)"
    fi
}

phase_provision_baked_stack() {
    local images service missing=""
    images=$(_ssh "podman ps --format '{{.Image}}'" 2>/dev/null | tr '\n' ' ')
    for service in tor monero p2pool xmrig-proxy dashboard; do
        case "$images" in *"pithead-$service"*) ;; *) missing="$missing $service" ;; esac
    done
    if [ -z "$missing" ]; then
        ok "every always-on service runs from the baked image set (#978)"
    else
        bad "services not running from baked images:$missing (running: ${images:-none})"
    fi
}
