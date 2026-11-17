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
    if _ssh "ips=\$(getent ahosts '$host' | awk '{print \$1}' | sort -u); [ -n \"\$ips\" ] || exit 1; for ip in \$ips; do case \$ip in *:*) t=ip6tables ;; *) t=iptables ;; esac; \$t -I OUTPUT 1 -p tcp -d \$ip --dport '$port' -m comment --comment pithead-978-registry-cut -j REJECT || exit 1; done"; then
        ok "the registry is unreachable from the guest for the whole of provisioning (#978)"
    else
        bad "could not cut the guest off from the registry (#978)"
        return 1
    fi
}

phase_provision_registry_untouched() {
    local hits
    hits=$(_ssh "{ iptables -L OUTPUT -v -n -x; ip6tables -L OUTPUT -v -n -x; } | awk '/pithead-978-registry-cut/ {sum += \$1; seen = 1} END {if (seen) print sum + 0; else print \"missing\"}'" 2>/dev/null | tr -d '\r\n')
    if [ "$hits" = 0 ]; then
        ok "provisioning never tried to reach the registry (#978)"
    else
        bad "provisioning sent ${hits:-unknown} packets at the cut-off registry (#978)"
    fi
}

registry_cut_pull_filter() {
    # shellcheck disable=SC2016
    printf '%s' '$6 == "image" && $7 == "pull" { pulled[$8] = $9 } $6 == "image" && $7 == "loadfromarchive" && ($8 in pulled) { print pulled[$8] }'
}

phase_provision_no_pull_before_load() {
    local pulled
    if ! pulled=$(_ssh "journalctl -b --no-pager -t podman -o cat | awk '$(registry_cut_pull_filter)'" 2>/dev/null); then
        bad "could not read the guest's podman events (#978)"
        return 1
    fi
    if [ -z "$pulled" ]; then
        ok "no baked image was pulled from a registry before its archive loaded (#978)"
    else
        bad "images pulled before their baked archive loaded: $(printf '%s' "$pulled" | tr '\n' ' ')"
    fi
}

phase_provision_baked_stack() {
    local images service missing=""
    images=$(_ssh "podman images --format '{{.Repository}}'" 2>/dev/null | tr '\n' ' ')
    for service in tor monero p2pool xmrig-proxy dashboard; do
        case "$images" in *"pithead-$service"*) ;; *) missing="$missing $service" ;; esac
    done
    if [ -z "$missing" ]; then
        ok "every always-on service image is loaded from the baked set (#978)"
    else
        bad "service images missing after provisioning:$missing (present: ${images:-none})"
    fi
}
