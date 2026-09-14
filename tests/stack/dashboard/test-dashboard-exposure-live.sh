# shellcheck shell=bash
: "${STACK_SUITE:?run through tests/stack/run.sh}"
# The KVM exposure row's tier-1 discrimination: one safe render, the existing public-bind mutation,
# and doctor's live-listener classifier (#2070).
# shellcheck source=tests/os/appliance-dashboard-exposure-leg.sh
source "$ROOT/tests/os/appliance-dashboard-exposure-leg.sh"
lan="192.168.1.$((5 + 5))"
network_prefix="172.28.$((0))"
ula="fd00::1"
global="2001:db8::1"

echo "== unit: dashboard appliance exposure stays private in config and live sockets (#2070) =="

render_exposure_caddy() { # <expose-public>
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
        appliance_mint_cert() { return 1; }
        hostname() { printf '%s %s.1 %s %s\n' "$lan" "$network_prefix" "$global" "$ula"; }
        DASHBOARD_SECURE=true DASHBOARD_HOST=pithead.local HOST_IP=pithead.local NETWORK_PREFIX="$network_prefix" DASHBOARD_AUTH_HASH_B64="" \
            DASHBOARD_EXPOSE_PUBLIC_IP="$1" generate_caddyfile >/dev/null 2>&1
        cat Caddyfile
    )
}

safe_caddy=$(render_exposure_caddy false)
open_caddy=$(render_exposure_caddy true)
safe_ss="LISTEN 0 4096 $lan:80 0.0.0.0:* users:((\"caddy\",pid=1,fd=6))
LISTEN 0 4096 $lan:443 0.0.0.0:* users:((\"caddy\",pid=1,fd=7))
LISTEN 0 4096 [$ula]:443 [::]:* users:((\"caddy\",pid=1,fd=8))"
public_ss="LISTEN 0 4096 [$global]:80 [::]:* users:((\"caddy\",pid=1,fd=7))
LISTEN 0 4096 $lan:443 0.0.0.0:* users:((\"caddy\",pid=1,fd=8))"
wild_ss="LISTEN 0 4096 [::]:80 [::]:* users:((\"caddy\",pid=1,fd=7))
LISTEN 0 4096 $lan:443 0.0.0.0:* users:((\"caddy\",pid=1,fd=8))"
stale_ss="LISTEN 0 4096 $lan:8443 0.0.0.0:* users:((\"caddy\",pid=1,fd=7))"
safe_doctor='{"checks":[{"status":"ok","message":"Dashboard listener excludes every public host address."}]}'

assert_contains "live exposure verdict accepts the safe render" \
    "$(dashboard_exposure_verdict "$safe_caddy" "$safe_ss" 7 "$safe_doctor" "$lan" "$ula" "$global" pithead.local)" "dashboard keeps"
assert_contains "live exposure verdict fires on the public-bind mutation" \
    "$(dashboard_exposure_verdict "$open_caddy" "$wild_ss" 0 '{}' "$lan" "$ula" "$global" pithead.local || true)" "wildcard listener"

assert_eq "dashboard listener verdict: LAN + ULA only" \
    "$(run_sourced "$SANDBOX" dashboard_public_listener_verdict "$safe_ss" "$global" 443)" ok
assert_contains "dashboard listener verdict: public v6 fails" \
    "$(run_sourced "$SANDBOX" dashboard_public_listener_verdict "$public_ss" "$global" 443 || true)" "public listener"
assert_contains "dashboard listener verdict: wildcard fails" \
    "$(run_sourced "$SANDBOX" dashboard_public_listener_verdict "$wild_ss" "$global" 443 || true)" "wildcard listener"
assert_eq "dashboard listener verdict: expected port is still required" \
    "$(run_sourced "$SANDBOX" dashboard_public_listener_verdict "$stale_ss" "$global" 443 || true)" missing

listener_bin="$SANDBOX/dashboard-listener-bin"
listener_env="$SANDBOX/dashboard-listener.env"
mkdir -p "$listener_bin"
printf '#!/usr/bin/env bash\nprintf '\''%%s\\n'\'' "${SS_OUT:-}"\n' >"$listener_bin/ss"
printf '#!/usr/bin/env bash\nprintf '\''2: eth0 inet6 2001:db8::1/64 scope global\\n'\''\n' >"$listener_bin/ip"
chmod +x "$listener_bin/ss" "$listener_bin/ip"
printf 'DASHBOARD_EXPOSE_PUBLIC_IP=false\nDASHBOARD_SECURE=true\nHOST_PORT=\n' >"$listener_env"
out="$(PITHEAD_APPLIANCE=1 ENV_FILE="$listener_env" SS_OUT="$safe_ss" PATH="$listener_bin:$PATH" run_sourced "$SANDBOX" check_dashboard_public_listener 2>&1)"
assert_contains "doctor dashboard listener: private sockets -> OK" "$out" "excludes every public host address"
out="$(PITHEAD_APPLIANCE=1 ENV_FILE="$listener_env" SS_OUT="$public_ss" PATH="$listener_bin:$PATH" run_sourced "$SANDBOX" check_dashboard_public_listener 2>&1)"
assert_contains "doctor dashboard listener: public socket -> FAIL" "$out" "FAIL"
