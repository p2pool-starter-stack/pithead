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
printf '#!/usr/bin/env bash\nprintf '\''%%s\\n'\'' "${IP_OUT-2: eth0 inet6 2001:db8::1/64 scope global}"\n' >"$listener_bin/ip"
chmod +x "$listener_bin/ss" "$listener_bin/ip"
printf 'DASHBOARD_EXPOSE_PUBLIC_IP=false\nDASHBOARD_SECURE=true\nHOST_PORT=\n' >"$listener_env"
out="$(PITHEAD_APPLIANCE=1 ENV_FILE="$listener_env" SS_OUT="$safe_ss" PATH="$listener_bin:$PATH" run_sourced "$SANDBOX" check_dashboard_public_listener 2>&1)"
assert_contains "doctor dashboard listener: private sockets -> OK" "$out" "excludes every public host address"
out="$(PITHEAD_APPLIANCE=1 ENV_FILE="$listener_env" SS_OUT="$public_ss" PATH="$listener_bin:$PATH" run_sourced "$SANDBOX" check_dashboard_public_listener 2>&1)"
assert_contains "doctor dashboard listener: public socket -> FAIL" "$out" "FAIL"
out="$(PITHEAD_APPLIANCE=1 ENV_FILE="$listener_env" IP_OUT='' SS_OUT="$wild_ss" PATH="$listener_bin:$PATH" run_sourced "$SANDBOX" check_dashboard_public_listener 2>&1)"
assert_contains "doctor dashboard listener: wildcard fails without a public IP" "$out" "FAIL"

phase_rc=0
(
    _ssh() {
        case "$1" in
        "cat "*) printf '%s' "$safe_caddy" ;;
        "ss "*) printf '%s' "$wild_ss" ;;
        "curl "*) return 1 ;;
        "cd "*) printf '%s' "$safe_doctor" ;;
        esac
    }
    bad() { :; }
    DASHBOARD_TEST_LAN_V4="$lan" DASHBOARD_TEST_ULA_V6="$ula" DASHBOARD_TEST_GLOBAL_V6="$global" \
        PROVISION_DASHBOARD_HOST=pithead.local phase_provision_dashboard_exposure
) || phase_rc=$?
assert_eq "failed exposure verdict fails the provision leg" "$phase_rc" 1

echo "== unit: dashboard appliance exposure stays private with the onion enabled (#2280) =="

render_onion_caddy() { # <expose-public>
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
        appliance_mint_cert() { return 1; }
        hostname() { printf '%s %s.1 %s %s\n' "$lan" "$network_prefix" "$global" "$ula"; }
        DASHBOARD_SECURE=true DASHBOARD_HOST=pithead.local HOST_IP=pithead.local NETWORK_PREFIX="$network_prefix" \
            DASHBOARD_AUTH_HASH_B64='$2y$14$UNITTESTbcrypthashvalue000000000000000000000000000000' \
            DASHBOARD_ONION_ENABLED=true DASHBOARD_EXPOSE_PUBLIC_IP="$1" generate_caddyfile >/dev/null 2>&1
        cat Caddyfile
    )
}

onion_caddy=$(render_onion_caddy false)
gw="$network_prefix.1"
onion_safe_ss="$safe_ss
LISTEN 0 4096 $gw:80 0.0.0.0:* users:((\"caddy\",pid=1,fd=9))"
onion_doctor='{"checks":[{"status":"ok","message":"Dashboard listener excludes every public host address."}]}'

assert_contains "onion exposure verdict accepts the safe onion render" \
    "$(dashboard_onion_exposure_verdict "$onion_caddy" "$onion_safe_ss" "$onion_doctor" "$gw")" "onion-enabled appliance keeps"
assert_contains "onion exposure verdict fires when the bridge listener never appears" \
    "$(dashboard_onion_exposure_verdict "$onion_caddy" "$safe_ss" "$onion_doctor" "$gw" || true)" "not listening on the onion bridge gateway"
assert_contains "onion exposure verdict fires on a wildcard listener" \
    "$(dashboard_onion_exposure_verdict "$onion_caddy" "$wild_ss" "$onion_doctor" "$gw" || true)" "wildcard listener"
assert_contains "onion exposure verdict fires on a wildcard listener" \
    "$(dashboard_onion_exposure_verdict "$onion_caddy" "$wild_ss" "$onion_doctor" "$gw" || true)" "wildcard listener"
assert_contains "onion exposure verdict fires when the Caddyfile drops the gateway bind" \
    "$(dashboard_onion_exposure_verdict "$safe_caddy" "$onion_safe_ss" "$onion_doctor" "$gw" || true)" "no onion vhost bound to the bridge gateway"

echo "== black-box: phase_provision_dashboard_onion_exposure always disables the onion again (#2280) =="
# Regression: an early guard that returns before the cleanup commit at the end of the phase would
# leave the appliance permanently onion-enabled. Drive the real phase function with dashboard_curl/
# dashboard_control_request/_ssh stubbed, forcing the guest's NETWORK_PREFIX read to come back
# empty (a live-listener read failure) — the phase must still report the failure AND still submit
# the disable commit, not skip it.
onion_call_log=$(mktemp)
onion_phase_out=$(
    # shellcheck disable=SC1090
    source "$STACK" 2>/dev/null
    set +e
    # A file, not a shell var: dashboard_control_request is invoked from inside $(...) command
    # substitutions in the real phase function, each of which forks a subshell — a plain counter
    # variable would reset every call instead of accumulating.
    dashboard_curl() { printf '{"dashboard":{"onion":{"enabled":false}}}'; }
    dashboard_config_body() { printf '{"config":%s}' "$1"; }
    dashboard_control_request() { # <route> <body>
        echo x >>"$onion_call_log"
        local n
        n=$(wc -l <"$onion_call_log" | tr -d ' ')
        case "$1:$n" in
        preview:1) printf '{"status":"previewed","destructive":true,"changes":[{"flag":"DEST"}],"id":"p1"}' ;;
        commit:2) printf '{"status":"rejected","error":"needs type APPLY"}' ;;
        preview:3) printf '{"status":"previewed","destructive":true,"changes":[{"flag":"DEST"}],"id":"p2"}' ;;
        *) printf '{"status":"applied"}' ;;
        esac
    }
    control_result_payload() { printf 'x'; }
    _ssh() { printf ''; } # NETWORK_PREFIX grep -> empty, the guard this test targets
    ok() { :; }
    bad() { printf 'BAD:%s\n' "$1"; }
    phase_provision_dashboard_onion_exposure admin secret
    printf 'CALLS:%s\n' "$(wc -l <"$onion_call_log" | tr -d ' ')"
)
rm -f "$onion_call_log"
assert_contains "phase still submits the disable commit after the NETWORK_PREFIX guard fires" "$onion_phase_out" "CALLS:6"
assert_contains "phase reports the NETWORK_PREFIX read failure" "$onion_phase_out" "BAD:onion exposure: could not read NETWORK_PREFIX"
