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

wizard_served_certificate() {
    timeout 10 openssl s_client -connect "$ip:443" </dev/null 2>/dev/null |
        openssl x509 -outform PEM 2>/dev/null
}

wizard_certificate_fingerprint() {
    local fingerprint
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 2>/dev/null) || return 1
    printf '%s' "${fingerprint#*=}" | tr '[:lower:]' '[:upper:]'
}

wizard_certificate_pin() {
    local digest
    digest=$(openssl x509 -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null |
        openssl dgst -sha256 -binary | openssl base64 -A) || return 1
    [ -n "$digest" ] || return 1
    printf 'sha256//%s' "$digest"
}

wizard_identity_request() {
    curl --noproxy '*' -sk --pinnedpubkey "$pin" -m 10 -o /dev/null -w '%{http_code}' "$@" "https://$ip/auth" 2>/dev/null
}

phase_wizard_identity() {
    local token printed served attempt code jar certificate pin
    token=$(wizard_console_token "$SERIAL")
    printed=$(wizard_console_fingerprint "$SERIAL") || printed=""
    certificate=$(wizard_served_certificate) || certificate=""
    served=$(printf '%s' "$certificate" | wizard_certificate_fingerprint) || served=""
    pin=$(printf '%s' "$certificate" | wizard_certificate_pin) || pin=""
    if [ -n "$printed" ] && [ "$printed" = "$served" ] && [ -n "$pin" ]; then
        ok "console SHA-256 fingerprint matches the setup certificate served over TLS"
    else
        bad "console SHA-256 fingerprint is missing, malformed or differs from the served certificate"
        return
    fi
    if [ -z "$token" ]; then
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
    jar=$(mktemp) || {
        bad "could not create a private setup session cookie jar"
        return
    }
    code=$(printf '%s' "$token" | wizard_identity_request -c "$jar" --data-urlencode token@-) || code=""
    if [ "$code" != 429 ] || grep -q wizard_session "$jar"; then
        rm -f "$jar"
        bad "the correct console token was not held at HTTP 429 during the cooldown"
        return
    fi
    ok "the correct console token waits out the cooldown from the throttled client"
    sleep 65
    code=$(printf '%s' "$token" | wizard_identity_request -c "$jar" --data-urlencode token@-) || code=""
    if [ "$code" != 302 ]; then
        rm -f "$jar"
        bad "the same console token did not authenticate after the cooldown"
        return
    fi
    code=$(curl --noproxy '*' -sk --pinnedpubkey "$pin" -m 10 -b "$jar" -o /dev/null -w '%{http_code}' "https://$ip/api/wizard-state" 2>/dev/null) || code=""
    rm -f "$jar"
    [ "$code" = 200 ] && ok "the same console token opens authenticated wizard state after the cooldown" ||
        bad "the authenticated session did not open wizard state after the cooldown"
}
