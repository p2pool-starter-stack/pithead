# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
auth_hb64="$(printf '%s' '$2y$14$UNITTESTbcrypthashvalue000000000000000000000000000000' | openssl base64 -A)"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_on="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_off="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
echo "== unit: generate_caddyfile session gate =="
assert_contains "login: session check goes through forward_auth" "$caddy_on" "forward_auth @pithead_session 127.0.0.1:8000"
assert_contains "login: forward_auth targets the dashboard check endpoint" "$caddy_on" "uri /api/auth/check"
assert_contains "login: forward_auth copies the actor from the session" "$caddy_on" "copy_headers X-Auth-User X-Pithead-Session-Refresh"
assert_contains "login: basic auth still gates scripts and API clients" "$caddy_on" "basic_auth @pithead_basic"
assert_contains "login: the basic-auth actor reaches the dashboard" "$caddy_on" "request_header @pithead_basic X-Auth-User {http.auth.user.id}"
assert_contains "login: client-supplied actor header is stripped first" "$caddy_on" "request_header -X-Auth-User"
assert_contains "login: the sign-in endpoints skip the gate" "$caddy_on" "@pithead_public path /login /api/auth/login /api/auth/logout"
assert_contains "login: basic auth is matched case-insensitively (RFC 7617)" "$caddy_on" "@pithead_basic header_regexp Authorization (?i)^basic\\s"
assert_contains "login: the sign-in route sets the client address itself" "$caddy_on" "header_up X-Forwarded-For {http.request.remote.host}"
assert_contains "login: a loopback-only verifier site exists" "$caddy_on" "http://127.0.0.1:8001 {"
assert_not_contains "login: the actor is no longer overwritten by the proxy" "$caddy_on" "header_up X-Auth-User"
epoch_on="$(printf '%s\n' "$caddy_on" | sed -n 's/.*header_up X-Pithead-Auth-Epoch "\([0-9a-f]*\)".*/\1/p' | sort -u)"
assert_eq "login: one 64-hex epoch is sent on every gated route" "$(printf '%s' "$epoch_on" | grep -cE '^[0-9a-f]{64}$')" "1"
auth_hb64_other="$(printf '%s' '$2y$14$UNITTESTbcrypthashvalue000000000000000000000000000001' | openssl base64 -A)"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_other="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64_other" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_not_contains "login: a new password changes the epoch" "$caddy_other" "$epoch_on"
assert_not_contains "no login: no session gate" "$caddy_off" "forward_auth"
assert_not_contains "no login: no verifier site" "$caddy_off" "127.0.0.1:8001"
assert_not_contains "no login: no epoch" "$caddy_off" "X-Pithead-Auth-Epoch"
assert_contains "no login: the sign-in paths are 404, as before" "$caddy_off" "respond @pithead_auth_paths 404"
assert_contains "no login: the actor placeholder still renders empty" "$caddy_off" "header_up X-Auth-User {http.auth.user.id}"
