# shellcheck shell=bash

dashboard_tls_identity() {
    local host port leaf fingerprint public_key sans key_digest
    host=$(env_on_box HOST_IP)
    port=$(env_on_box HOST_PORT)
    port=${port:-443}
    [ -n "$host" ] && [[ "$port" =~ ^[0-9]+$ ]] || return 1
    leaf=$(rx "timeout 15 openssl s_client -connect 127.0.0.1:$port -servername $(quote_arg "$host") </dev/null 2>/dev/null" |
        openssl x509 -outform PEM 2>/dev/null) || return 1
    fingerprint=$(printf '%s\n' "$leaf" | openssl x509 -noout -fingerprint -sha256 2>/dev/null) || return 1
    public_key=$(printf '%s\n' "$leaf" | openssl x509 -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256) || return 1
    sans=$(printf '%s\n' "$leaf" | openssl x509 -noout -ext subjectAltName 2>/dev/null |
        tail -n +2 | tr ',' '\n' | tr -d '[:blank:]' | LC_ALL=C sort -u | tr '\n' ',') || return 1
    key_digest=$(rx 'set -o pipefail; keys=$(timeout 15 docker exec caddy sh -c '\''if test -s /pithead-tls/wizard.key; then sha256sum /pithead-tls/wizard.key; else find /data/caddy/certificates -type f -name "*.key" -exec sha256sum {} \; | sort; fi'\'') && test -n "$keys" && printf "%s\n" "$keys" | sha256sum') || return 1
    [ -n "$fingerprint" ] && [ -n "$public_key" ] && [ -n "$sans" ] && [ -n "$key_digest" ] || return 1
    printf '%s|%s|%s|%s\n' "$fingerprint" "$public_key" "$sans" "$key_digest"
}

assert_dashboard_tls_continuity() {
    local label="$1" before="$2" after="" deadline=$(($(date +%s) + 90))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        after=$(dashboard_tls_identity) && break
        sleep 3
    done
    if [ -z "$before" ] || [ -z "$after" ]; then
        it_fail "$label preserves the served TLS certificate and key" "TLS identity could not be read before or after the operation"
        return 1
    fi
    if [ "$before" != "$after" ]; then
        it_fail "$label preserves the served TLS certificate and key" "served fingerprint, public key, canonical SANs or local private-key digest changed"
        return 1
    fi
    it_pass "$label preserves the served TLS certificate and key"
}

run_password_tls_continuity() {
    local saved before changed password failures="$IT_FAIL"
    saved=$(rx 'cat config.json') || {
        it_fail "password apply TLS fixture reads its starting config" "config unavailable"
        return 1
    }
    before=$(dashboard_tls_identity) || before=""
    password=$(openssl rand -hex 24) || return 1
    changed=$(printf '%s' "$saved" | jq --arg password "$password" '.dashboard.auth.password = $password') || return 1
    if push_config "$changed" && pithead apply -y >/dev/null 2>&1 && wait_status_ok 240; then
        assert_dashboard_tls_continuity "dashboard password apply" "$before" || true
    else
        it_fail "dashboard password apply preserves the served TLS certificate and key" "apply failed or stack did not recover"
    fi
    if ! push_config "$saved" || ! pithead apply -y >/dev/null 2>&1 || ! wait_status_ok 240; then
        it_fail "password apply TLS fixture restores the original config" "baseline apply or health recovery failed"
        return 1
    fi
    assert_dashboard_tls_continuity "dashboard password restore apply" "$before" || true
    [ "$IT_FAIL" -eq "$failures" ]
}
