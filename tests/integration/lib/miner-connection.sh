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

# Match the daemon's actual argv against the configured mode and rendered container env.
# Docker .Args predates the entrypoint's appended password flag and cannot prove this.
proxy_password_matches() { # <argv-json> <configured-password> <container-env-json>
    printf '%s' "$1" | jq -e --arg configured "$2" --argjson env "$3" '
        if type != "array" or length == 0 or any(.[]; type != "string") or
            ($env | type != "array" or any(.[]; type != "string")) then false
        else
            ([$env[] | select(startswith("PROXY_STRATUM_PASSWORD="))]) as $entries |
            ($entries[0] // "" | ltrimstr("PROXY_STRATUM_PASSWORD=")) as $password |
            ([.[] | select(startswith("--access-password"))]) as $flags |
            (.[0] | test("(^|/)xmrig-proxy$")) and ($entries | length == 1) and
            (if $configured == "" then $password == "" and $flags == []
            else $password != "" and ($configured == "auto" or $configured == $password) and
                $flags == ["--access-password=" + $password]
            end)
        end'
}

assert_proxy_password_live() { # <config-json>
    local configured argv env row="stratum password matches live daemon argv (#152/#3092)"
    if ! configured=$(printf '%s' "$1" | jq -er '.p2pool.stratum_password | if . == null then "" elif type == "string" then . else error("invalid password mode") end' 2>/dev/null) ||
        ! argv=$(rx "set -o pipefail; docker exec xmrig-proxy cat /proc/1/cmdline | jq -Rs 'split(\"\\u0000\") | .[:-1]'" 2>/dev/null) ||
        ! env=$(rx "docker inspect xmrig-proxy --format '{{json .Config.Env}}'" 2>/dev/null); then
        it_fail "$row" "config, daemon argv or rendered environment unavailable"
    elif proxy_password_matches "$argv" "$configured" "$env" >/dev/null 2>&1; then
        it_pass "$row"
    else
        it_fail "$row" "configured mode, rendered password and daemon flag differ"
    fi
}
