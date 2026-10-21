# shellcheck shell=bash
# shellcheck disable=SC2154
wizard_console_token() {
    sed -nE 's/.*One-time token: (pit-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{6}).*/\1/p' "$1" | tail -n 1
}

wizard_console_fingerprint() {
    local fingerprint
    fingerprint=$(sed -nE 's/.*SHA-256: ([0-9A-Fa-f:]+).*/\1/p' "$1" | tail -n 1)
    [[ "$fingerprint" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]] || return 1
    printf '%s' "$fingerprint" | tr '[:lower:]' '[:upper:]'
}

wizard_served_fingerprint() {
    local fingerprint
    fingerprint=$(timeout 10 openssl s_client -connect "$ip:443" </dev/null 2>/dev/null |
        openssl x509 -noout -fingerprint -sha256 2>/dev/null) || return 1
    fingerprint=${fingerprint#*=}
    [[ "$fingerprint" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]] || return 1
    printf '%s' "$fingerprint" | tr '[:lower:]' '[:upper:]'
}

wizard_identity_request() {
    curl --noproxy '*' -sk -m 10 -o /dev/null -w '%{http_code}' "$@" "https://$ip/auth" 2>/dev/null
}

phase_wizard_identity() {
    local old_token new_token printed served attempt code deadline jar
    old_token=$(wizard_console_token "$SERIAL")
    printed=$(wizard_console_fingerprint "$SERIAL") || printed=""
    served=$(wizard_served_fingerprint) || served=""
    if [ -n "$printed" ] && [ "$printed" = "$served" ]; then
        ok "console SHA-256 fingerprint matches the setup certificate served over TLS"
    else
        bad "console SHA-256 fingerprint is missing, malformed or differs from the served certificate"
        return
    fi
    if [ -z "$old_token" ]; then
        bad "console did not print a usable one-time setup token"
        return
    fi
    for attempt in 1 2 3 4 5; do
        code=$(wizard_identity_request --data-urlencode token=wrong-token) || code=""
        if { [ "$attempt" -lt 5 ] && [ "$code" != 403 ]; } ||
            { [ "$attempt" -eq 5 ] && [ "$code" != 429 ]; }; then
            bad "wrong setup token attempt $attempt returned an unexpected HTTP status"
            return
        fi
    done
    ok "five wrong setup tokens return four HTTP 403 refusals then HTTP 429"
    deadline=$(($(date +%s) + 120))
    new_token=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        new_token=$(wizard_console_token "$SERIAL")
        if [ -n "$new_token" ] && [ "$new_token" != "$old_token" ]; then
            code=$(curl --noproxy '*' -sk -m 10 -o /dev/null -w '%{http_code}' "https://$ip/" 2>/dev/null) || code=""
            [ "$code" != 200 ] || break
        fi
        sleep 2
    done
    if [ -z "$new_token" ] || [ "$new_token" = "$old_token" ] || [ "$code" != 200 ]; then
        bad "lockout did not print a fresh console token and reopen the setup page within 120 seconds"
        return
    fi
    ok "lockout prints a fresh console token and reopens the setup page"
    code=$(wizard_identity_request --data-urlencode "token=$old_token") || code=""
    if [ "$code" != 403 ]; then
        bad "the previous console token was not refused after lockout"
        return
    fi
    jar=$(mktemp) || {
        bad "could not create a private setup session cookie jar"
        return
    }
    code=$(wizard_identity_request -c "$jar" --data-urlencode "token=$new_token") || code=""
    if [ "$code" != 302 ]; then
        rm -f "$jar"
        bad "the fresh console token did not authenticate"
        return
    fi
    code=$(curl --noproxy '*' -sk -m 10 -b "$jar" -o /dev/null -w '%{http_code}' "https://$ip/api/wizard-state" 2>/dev/null) || code=""
    rm -f "$jar"
    [ "$code" = 200 ] && ok "the previous token is refused and the fresh token opens authenticated wizard state" ||
        bad "the fresh console token did not open authenticated wizard state"
}
