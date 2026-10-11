# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Caddy bind list vs container bridges (#3406): generate_caddyfile never binds an address an
# engine interface holds, because that interface can be gone when Caddy starts.
echo "== unit: generate_caddyfile bind list excludes container-bridge addresses (#3406) =="
# A container bridge the engine (or the setup wizard) created is in `hostname -I` when the Caddyfile
# renders and can be gone when `up` starts Caddy; a bind on that literal fails the whole file with
# "cannot assign requested address" and Caddy crash-loops (#3406). The bind keeps the LAN and ULA
# addresses and drops every address an engine interface holds, while the site list still names them.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_bridge="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
    appliance_mint_cert() { return 1; }
    hostname() { printf '192.168.1.10 10.89.0.1 172.28.0.1 fd00::1 fd00:89::1\n'; }
    ip() {
        printf '%s\n' \
            '1: lo    inet 127.0.0.1/8 scope host lo' \
            '2: enp1s0    inet 192.168.1.10/24 brd 192.168.1.255 scope global enp1s0' \
            '2: enp1s0    inet6 fd00::1/64 scope global enp1s0' \
            '5: podman2    inet 10.89.0.1/24 brd 10.89.0.255 scope global podman2' \
            '5: podman2    inet6 fd00:89::1/64 scope global podman2' \
            '6: br-0123456789ab    inet 172.28.0.1/24 scope global br-0123456789ab'
    }
    DASHBOARD_SECURE=true HOST_IP=pithead.local DASHBOARD_AUTH_HASH_B64="" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
bridge_bind="$(printf '%s' "$caddy_bridge" | grep '^    bind ' | sort -u)"
assert_eq "the bind keeps the LAN, ULA and loopback and drops every container-bridge address" \
    "$bridge_bind" "    bind 192.168.1.10 fd00::1 127.0.0.1 ::1"
