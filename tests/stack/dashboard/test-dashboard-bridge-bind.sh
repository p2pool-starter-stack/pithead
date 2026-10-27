# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Caddy bind list vs container bridges (#3406): generate_caddyfile never binds an address an
# engine interface holds, because that interface can be gone when Caddy starts.
echo "== unit: generate_caddyfile bind list excludes container-bridge addresses (#3406) =="
# A container bridge the engine (or the setup wizard) created is in `hostname -I` when the Caddyfile
# renders and can be gone when `up` starts Caddy; a bind on that literal fails the whole file with
# "cannot assign requested address" and Caddy crash-loops (#3406). The bind keeps the LAN and ULA
# addresses and drops every address an engine interface holds. The site list and certificate names drop them
# too: a name that appears only after `up` made the address watch re-render and restart a healthy Caddy.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_bridge="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
    appliance_mint_cert() { return 1; }
    hostname() { printf '192.168.1.10 10.89.0.1 172.28.0.1 fd00::1 fd00:89::1 192.168.50.2 192.168.60.2\n'; }
    ip() {
        printf '%s\n' \
            '1: lo    inet 127.0.0.1/8 scope host lo' \
            '2: enp1s0    inet 192.168.1.10/24 brd 192.168.1.255 scope global enp1s0' \
            '2: enp1s0    inet6 fd00::1/64 scope global enp1s0' \
            '5: podman2    inet 10.89.0.1/24 brd 10.89.0.255 scope global podman2' \
            '5: podman2    inet6 fd00:89::1/64 scope global podman2' \
            '3: br0    inet 192.168.50.2/24 scope global br0' \
            '4: br-lan    inet 192.168.60.2/24 scope global br-lan' \
            '6: br-0123456789ab    inet 172.28.0.1/24 scope global br-0123456789ab'
    }
    DASHBOARD_SECURE=true HOST_IP=pithead.local DASHBOARD_AUTH_HASH_B64="" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
bridge_bind="$(printf '%s' "$caddy_bridge" | grep '^    bind ' | sort -u)"
assert_eq "the bind keeps the LAN, ULA and loopback and drops engine bridges but keeps LAN bridges (br0, br-lan)" \
    "$bridge_bind" "    bind 192.168.1.10 fd00::1 192.168.50.2 192.168.60.2 127.0.0.1 ::1"
site_line="$(printf '%s' "$caddy_bridge" | grep -m1 '^https://pithead.local')"
assert_eq "the site list keeps the LAN addresses and drops every engine bridge address" "$site_line" \
    "https://pithead.local, https://192.168.1.10, https://fd00::1, https://192.168.50.2, https://192.168.60.2, https://localhost {"

echo "== unit: configured mining gateway stays out of LAN sites and binds without bridge discovery =="
for gateway_host in "" dashboard.example; do
    for gateway_onion in false true; do
        # shellcheck disable=SC1090
        caddy_gateway="$(
            cd "$SANDBOX" && source "$STACK" 2>/dev/null
            set +e
            is_appliance() { return 0; }
            appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
            appliance_mint_cert() { return 1; }
            hostname() { printf '192.168.1.10 10.77.42.1 fd00::1\n'; }
            ip() { return 1; }
            DASHBOARD_SECURE=true DASHBOARD_HOST="$gateway_host" HOST_IP="${gateway_host:-pithead.local}" \
                NETWORK_PREFIX=10.77.42 DASHBOARD_EXPOSE_PUBLIC_IP=false \
                DASHBOARD_ONION_ENABLED="$gateway_onion" DASHBOARD_ONION=abcdefghij234567.onion \
                DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
                generate_caddyfile >/dev/null 2>&1
            cat Caddyfile
        )"
        gateway_label="host=${gateway_host:-auto}, onion=$gateway_onion"
        gateway_lan_binds=$(printf '%s\n' "$caddy_gateway" | awk '/^    bind / && $0 != "    bind 10.77.42.1"' | sort -u)
        assert_eq "$gateway_label: LAN binds exclude the configured gateway without bridge discovery" \
            "$gateway_lan_binds" "    bind 192.168.1.10 fd00::1 127.0.0.1 ::1"
        assert_not_contains "$gateway_label: LAN sites exclude the configured gateway" \
            "$(printf '%s\n' "$caddy_gateway" | grep '^https://')" "https://10.77.42.1"
        if [ "$gateway_onion" = true ]; then
            assert_eq "$gateway_label: both onion vhosts retain their gateway bind" \
                "$(printf '%s\n' "$caddy_gateway" | grep -c '^    bind 10.77.42.1$')" 2
        else
            assert_not_contains "$gateway_label: onion-disabled render never names the gateway" \
                "$caddy_gateway" "10.77.42.1"
        fi
    done
done
