# shellcheck shell=bash
# Shared verdict for the live Compose and appliance connection endpoint. Never echo secrets.
miner_connection_matches() { # <body> <password> <tls> <certificate-digest> <port>
    printf '%s' "$1" | jq -e --arg password "$2" --argjson tls "$3" --arg fp "$4" --arg port "$5" '
        .password == $password and .password_set == ($password != "") and
        .tls == $tls and .fingerprint == $fp and
        (.url | test("^stratum\\+" + (if $tls then "ssl" else "tcp" end) + "://[^/]+:" + $port + "$"))'
}

assert_miner_connection_live() {
    local response headers body password tls fingerprint="" dir port
    response=$(rx 'curl -fsS --max-time 15 -D - http://127.0.0.1:8000/api/miner-connection' 2>/dev/null) || {
        it_fail "Connect a miner endpoint responds (#3092)" "request failed"
        return
    }
    response=${response//$'\r'/}
    headers=${response%%$'\n\n'*}
    body=${response#*$'\n\n'}
    if printf '%s\n' "$headers" | grep -Eiq '^Cache-Control: no-store$'; then
        it_pass "Connect a miner credentials are not cached (#3092)"
    else
        it_fail "Connect a miner credentials are not cached (#3092)" "no no-store header"
    fi
    password=$(env_on_box PROXY_STRATUM_PASSWORD)
    tls=$(env_on_box PROXY_STRATUM_TLS)
    port=$(env_on_box STRATUM_PORT)
    if [ "$tls" = true ]; then
        dir=$(env_on_box PROXY_TLS_DIR)
        fingerprint=$(rx "openssl x509 -in $(quote_arg "$dir/cert.pem") -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'")
        [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || {
            it_fail "Connect a miner matches the installed identity (#3092)" "certificate digest unavailable"
            return
        }
    fi
    if miner_connection_matches "$body" "$password" "$tls" "$fingerprint" "$port" >/dev/null 2>&1; then
        it_pass "Connect a miner matches the installed identity (#3092)"
    else
        it_fail "Connect a miner matches the installed identity (#3092)" "URL, password, TLS mode or certificate digest differs"
    fi
}
