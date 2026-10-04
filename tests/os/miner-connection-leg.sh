# shellcheck shell=bash
# Hand-off to installed dashboard identity, without printing either password.
source "${BASH_SOURCE[0]%/*}/../integration/lib/miner-connection.sh" || return $?

wizard_miner_connection_card_valid() { # <hand-off> <password-mode> <tls>
    printf '%s' "$1" | jq -e --arg mode "$2" --argjson tls "$3" '
        .stratum_tls == $tls and
        (if $mode == "off" then .stratum_password == ""
         else (.stratum_password | test("^[0-9a-f]{24}$")) end) and
        (if $tls then (.stratum_fingerprint | test("^[0-9a-f]{64}$"))
         else .stratum_fingerprint == "" end) and
        (.stratum | test("^stratum\\+" + (if $tls then "ssl" else "tcp" end) + "://[^/]+:3333$"))' >/dev/null 2>&1
}

# shellcheck disable=SC2034,SC2154 # runner's ip and dashboard_curl's dynamically scoped login.
phase_miner_connection_installed() { # <hand-off>
    local card="$1" response headers body password tls fingerprint="" expected password_mode
    local DASH_USER DASH_PASS
    DASH_USER=$(jq -r '.username' <<<"$card")
    DASH_PASS=$(jq -r '.password' <<<"$card")
    response=$(dashboard_curl -fsSk -m 15 -D - "https://$ip/api/miner-connection" 2>/dev/null) || {
        bad "installed Connect a miner endpoint responds (#3092)"
        return 1
    }
    response=${response//$'\r'/}
    headers=${response%%$'\n\n'*}
    body=${response#*$'\n\n'}
    if printf '%s\n' "$headers" | grep -Eiq '^Cache-Control: no-store$'; then
        ok "installed Connect a miner credentials are not cached (#3092)"
    else
        bad "installed Connect a miner credentials are not cached (#3092)"
    fi
    password=$(_ssh "sed -n 's/^PROXY_STRATUM_PASSWORD=//p' /data/pithead/.env")
    password_mode=$(_ssh "jq -r '.p2pool.stratum_password // \"\"' /data/pithead/config.json")
    expected=$(jq -r '.stratum_password' <<<"$card")
    tls=$(jq -r '.stratum_tls' <<<"$card")
    if [ "$tls" = true ]; then
        fingerprint=$(_ssh "openssl x509 -in /data/pithead/data/proxy-tls/cert.pem -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'")
        [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || {
            bad "hand-off TLS identity survives installation (#3092)"
            return 1
        }
    fi
    if [ "$password" = "$expected" ] && [ "$fingerprint" = "$(jq -r '.stratum_fingerprint' <<<"$card")" ] &&
        { [ -z "$expected" ] && [ "$password_mode" = "" ] || [ -n "$expected" ] && [ "$password_mode" = auto ]; }; then
        ok "hand-off password and TLS identity survive setup and installation (#3092)"
    else
        bad "hand-off password and TLS identity survive setup and installation (#3092)"
    fi
    if miner_connection_matches "$body" "$expected" "$tls" "$fingerprint" 3333 >/dev/null 2>&1 &&
        jq -e --arg ip "$ip" '.url | contains("://" + $ip + ":3333")' <<<"$body" >/dev/null; then
        ok "installed Connect a miner shows the LAN URL and hand-off identity (#3092)"
    else
        bad "installed Connect a miner shows the LAN URL and hand-off identity (#3092)"
    fi
}
