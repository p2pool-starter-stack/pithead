#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/wizard-identity-leg.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
SERIAL="$scratch/serial"
export ip=192.0.2.10
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=wizard-test \
    -keyout "$scratch/key" -out "$scratch/cert" >/dev/null 2>&1
expected=$(openssl x509 -in "$scratch/cert" -noout -fingerprint -sha256)
fingerprint=${expected#*=}
mismatch_fingerprint="00${fingerprint:2}"
[ "$mismatch_fingerprint" != "$fingerprint" ] || mismatch_fingerprint="FF${fingerprint:2}"
printf '  One-time token: pit-AAAAA2\r\n  SHA-256: %s\r\n' "$fingerprint" >"$SERIAL"
[ "$(wizard_console_token "$SERIAL")" = pit-AAAAA2 ]
[ "$(wizard_console_fingerprint "$SERIAL")" = "$fingerprint" ]
printf 'SHA-256: AB:CD\n' >"$scratch/malformed"
if wizard_console_fingerprint "$scratch/malformed"; then exit 1; fi
if [ -n "$(wizard_console_token "$scratch/malformed")" ]; then exit 1; fi
timeout() { cat "$scratch/cert"; }
[ "$(wizard_served_certificate | wizard_certificate_fingerprint)" = "$fingerprint" ]
if printf invalid | wizard_certificate_fingerprint; then exit 1; fi
if printf invalid | wizard_certificate_pin; then exit 1; fi
wizard_served_certificate() {
    [ "$scenario" != missing-certificate ] || return 1
    cat "$scratch/cert"
}
ok() {
    passes=$((passes + 1))
    printf 'PASS %s\n' "$*" >>"$scratch/rows"
}
bad() {
    failures=$((failures + 1))
    printf 'FAIL %s\n' "$*" >>"$scratch/rows"
}
sleep() { :; }
date() {
    local ticks
    ticks=$(cat "$scratch/ticks")
    printf '%s' "$((ticks + 60))" >"$scratch/ticks"
    printf '%s' "$ticks"
}
curl() {
    local args="$*" count token
    [[ "$args" == *"--pinnedpubkey sha256//"* ]] || return 2
    [ "$scenario" != changed-key ] || return 90
    [[ "$args" != *pit-AAAAA2* && "$args" != *pit-AAAAA3* ]] || return 2
    case "$args" in
    *token=wrong-token*)
        count=$(cat "$scratch/attempts")
        count=$((count + 1))
        printf '%s' "$count" >"$scratch/attempts"
        if [ "$scenario" = early-lockout ] && [ "$count" -eq 4 ]; then
            printf 429
        elif [ "$count" -eq 5 ]; then
            [ "$scenario" = no-rotation ] || printf 'One-time token: pit-AAAAA3\n' >>"$SERIAL"
            if [ "$scenario" = restarted-mismatch ]; then
                printf 'SHA-256: %s\n' "$mismatch_fingerprint" >>"$SERIAL"
            fi
            if [ "$scenario" = no-lockout ]; then printf 403; else printf 429; fi
        else
            printf 403
        fi
        ;;
    *token@-*)
        token=$(cat)
        case "$token" in
        pit-AAAAA2)
            if [ "$scenario" = old-accepted ]; then printf 302; else printf 403; fi
            ;;
        pit-AAAAA3)
            if [ "$scenario" = new-refused ]; then printf 403; else printf 302; fi
            ;;
        *) return 2 ;;
        esac
        ;;
    *api/wizard-state*)
        if [ "$scenario" = no-session ]; then printf 401; else printf 200; fi
        ;;
    *)
        if [ "$scenario" = unavailable ]; then
            printf 000
            return 7
        else printf 200; fi
        ;;
    esac
}
for scenario in healthy mismatch missing-certificate early-lockout no-lockout no-rotation unavailable old-accepted new-refused no-session changed-key restarted-mismatch; do
    printf 'One-time token: pit-AAAAA2\nSHA-256: %s\n' "$fingerprint" >"$SERIAL"
    if [ "$scenario" = mismatch ]; then
        printf 'SHA-256: %s\n' "$mismatch_fingerprint" >>"$SERIAL"
    fi
    printf 0 >"$scratch/attempts"
    printf 0 >"$scratch/ticks"
    : >"$scratch/rows"
    passes=0 failures=0
    phase_wizard_identity
    if [ "$scenario" = healthy ]; then
        [ "$passes" = 4 ] && [ "$failures" = 0 ]
        [ "$(grep -c '^PASS ' "$scratch/rows")" = 4 ]
        if grep -q '^FAIL ' "$scratch/rows"; then exit 1; fi
        [ "$(cat "$scratch/attempts")" = 5 ]
    else
        [ "$failures" = 1 ]
        grep -q '^FAIL ' "$scratch/rows"
    fi
done
printf 'selftest-wizard-identity: PASS\n'
