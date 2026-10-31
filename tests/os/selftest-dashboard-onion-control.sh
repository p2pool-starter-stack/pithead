#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/appliance-dashboard-exposure-leg.sh
source "$HERE/appliance-dashboard-exposure-leg.sh"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fixture_onion="$(printf 'a%.0s' {1..56}).onion"
key="$(printf 'A%.0s' {1..52})"
fixture_id=11111111-1111-4111-8111-111111111111
ip="fixture-address"
jq -nc --arg o "$fixture_onion" --arg k "$key" '["DASHBOARD_ONION_ENABLED=true", "DASHBOARD_ONION_ADDRESS="+$o,
    "DASHBOARD_ONION_CLIENT_AUTH=true", "UNRELATED_SECRET="+$k]' >"$fixture/runtime.json"
ok() { printf 'ok: %s\n' "$1"; }
bad() {
    FAIL=$((FAIL + 1))
    printf 'bad: %s\n' "$1"
}
sleep() { :; }
dashboard_curl() {
    [ "$shape" != state-unreadable ] || return 1
    if [ "$shape" = state-delay ] && [ ! -e "$fixture/read" ]; then
        touch "$fixture/read"
        printf '{"dashboard_onion":null}\n200'
        return
    fi
    if [ "$shape" = state-malformed ]; then
        printf '%s\n200' "$key"
        return
    fi
    jq -nc --arg onion "$fixture_onion" --arg shape "$shape" '
        {dashboard_onion:{url:(if $shape == "state-mismatch" then "http://wrong.onion" else "http://" + $onion end),
                          client_auth:($shape != "state-noauth")}}'
    if [ "$shape" = state-unauthorized ]; then printf '\n401'; else printf '\n200'; fi
}
dashboard_control_request() {
    [ "$1" = onion-client-key ] && [ "$2" = '{}' ] || return 1
    touch "$fixture/request"
    [ "$shape" != request-failed ] || return 1
    jq -nc --arg id "$fixture_id" --arg o "$fixture_onion" --arg k "$key" --arg shape "$shape" '
        {id:$id,status:"applied",onion_url:("http://" + $o),client_key:$k,
         torrc_line:(($o | sub("\\.onion$"; "")) + ":descriptor:x25519:" + $k)} |
        if $shape == "key-mismatch" then .torrc_line = "wrong"
        elif $shape == "key-missing" then del(.client_key)
        elif $shape == "key-empty" then .client_key = ""
        elif $shape == "id-hostile" then .id = "../bad"
        elif $shape == "rejected" then .status = "rejected"
        else . end'
}
_ssh() {
    local cmd="$1"
    cmd=${cmd//\/data\/pithead/$fixture}
    FIXTURE_ONION="$fixture_onion" FIXTURE_RUNTIME="$fixture/runtime.json" bash -euo pipefail -c '
        podman() {
            if [ "$1" = inspect ]; then cat "$FIXTURE_RUNTIME"; else printf "%s" "$FIXTURE_ONION"; fi
        }
        eval "$1"
    ' fixture "$cmd"
}

for shape in good state-delay hostname-mismatch state-mismatch state-noauth state-unreadable state-unauthorized state-malformed \
    request-failed key-mismatch key-missing key-empty id-hostile rejected audit-missing audit-other \
    retained-key retained-line result-missing redaction-fields-missing; do
    mkdir -p "$fixture/data/control/audit" "$fixture/data/control/results"
    rm -f "$fixture/read" "$fixture/request"
    printf 'DASHBOARD_ONION_ADDRESS=%s\n' "$fixture_onion" >"$fixture/.env"
    [ "$shape" != hostname-mismatch ] || printf 'DASHBOARD_ONION_ADDRESS=wrong.onion\n' >"$fixture/.env"
    jq -nc --arg id "$fixture_id" --arg shape "$shape" '
        {id:(if $shape == "audit-other" then "different" else $id end),
         action:"onion-client-key",status:"applied"}' >"$fixture/data/control/audit/control.log"
    [ "$shape" != audit-missing ] || : >"$fixture/data/control/audit/control.log"
    jq -nc --arg o "$fixture_onion" --arg k "$key" --arg shape "$shape" '
        {status:"applied",onion_url:("http://" + $o),client_key:null,torrc_line:null} |
        if $shape == "retained-key" then .client_key = $k
        elif $shape == "retained-line" then .torrc_line = $k
        elif $shape == "redaction-fields-missing" then del(.client_key,.torrc_line)
        else . end' >"$fixture/data/control/results/$fixture_id.json"
    [ "$shape" != result-missing ] || rm -f "$fixture/data/control/results/$fixture_id.json"
    FAIL=0
    phase_provision_dashboard_onion_control >"$fixture/output" 2>&1 || true
    case "$shape" in
    good | state-delay)
        [ "$FAIL" -eq 0 ] && [ "$(grep -c '^ok:' "$fixture/output")" -eq 5 ] && [ -e "$fixture/request" ] || {
            cat "$fixture/output"
            exit 1
        }
        ;;
    *) [ "$FAIL" -gt 0 ] || {
        printf 'false PASS: %s\n' "$shape"
        exit 1
    } ;;
    esac
    if grep -Fq "$key" "$fixture/output" || grep -Fq "$fixture_onion" "$fixture/output"; then
        printf 'credential or onion leaked: %s\n' "$shape"
        exit 1
    fi
    case "$shape" in
    state-mismatch | state-noauth | state-unreadable | state-unauthorized | state-malformed)
        grep -Fq '"runtime_enabled":true,"runtime_address_matches":true,"runtime_client_auth":true' "$fixture/output" || exit 1
        ;;
    esac
    printf 'PASS %s\n' "$shape"
done

(
    _control_requests_drained() { return 0; }
    approval_capture_restore_snapshot() { return 0; }
    approval_restore_pending() { restored=$((restored + 1)); }
    dashboard_onion_exposure_verdict() { return 0; }
    _ssh() {
        case "$1" in
        *NETWORK_PREFIX*) printf 'fixture-prefix' ;;
        *) return 0 ;;
        esac
    }
    phase_provision_dashboard_onion_control() {
        [ "$DASH_USER" = fixture-user ] && [ "$DASH_PASS" = fixture-password ] || return 1
        authenticated=1
        bad "injected onion control failure"
        return 1
    }
    FAIL=0 restored=0 authenticated=0
    phase_provision_dashboard_onion_exposure fixture-user fixture-password >"$fixture/cleanup-output" 2>&1
    [ "$FAIL" -gt 0 ] && [ "$restored" -eq 1 ] && [ "$authenticated" -eq 1 ]
) || {
    printf 'FAIL restore after control failure\n'
    exit 1
}
printf 'PASS restore after control failure\n'

for raw in "$key" "<html>$key</html>" \
    "$(jq -nc --arg k "$key" '{dashboard_onion:{url:$k,client_auth:$k},error:$k}')"; do
    diagnostic=$(dashboard_onion_state_evidence "$raw" 401 22 "$fixture_onion")
    printf '%s' "$diagnostic" | jq -e '.http == "401" and .curl == 22 and .url_matches == false and .client_auth == false' >/dev/null
    if grep -Fq "$key" <<<"$diagnostic"; then exit 1; fi
done
printf 'PASS bounded state diagnostics never expose payload values\n'
