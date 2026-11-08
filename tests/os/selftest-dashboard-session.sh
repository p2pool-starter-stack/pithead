#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

dashboard_session_self_test() {
    local ip=fixture DASH_USER=user DASH_PASS='first pass' calls request_body jar_arg previous url out args EXPECTED_ORIGIN EXPECTED_RESOLVE EXPECT_REQUEST=0
    local REQUEST_JSON='{"symbolicfixture":true}'
    local DASHBOARD_SESSION_DIR
    DASHBOARD_SESSION_DIR=$(mktemp -d) || return 1
    calls=$(mktemp)
    request_body=$(mktemp)
    curl() {
        url="${!#}" jar_arg="" previous=""
        for arg in "$@"; do
            [ "$previous" != -b ] && [ "$previous" != -c ] || jar_arg="$arg"
            previous="$arg"
        done
        case "$url" in
        */login)
            args=" $* "
            [ "$url" = "${EXPECTED_ORIGIN:-https://$ip}/login" ] || return 1
            case "$args" in *" Origin: ${EXPECTED_ORIGIN:-https://$ip} "*) ;; *) return 1 ;; esac
            [ -z "${EXPECTED_RESOLVE:-}" ] || case "$args" in *" --resolve $EXPECTED_RESOLVE "*) ;; *) return 1 ;; esac
            case "$args" in *' -D '* | *' Content-Type: application/json '*) return 1 ;; esac
            case "$args" in *' -u '* | *' Authorization: '* | *"$DASH_USER"* | *"$DASH_PASS"*) return 1 ;; esac
            [ "$(cat)" = "username=user&password=$(python3 -c 'import urllib.parse; print(urllib.parse.quote_plus("'"$DASH_PASS"'"))')" ] || return 1
            printf 'session\n' >"$jar_arg"
            printf 303
            printf 'login\n' >>"$calls"
            ;;
        */api/auth/session)
            args=" $* "
            [ -z "${EXPECTED_RESOLVE:-}" ] || case "$args" in *" --resolve $EXPECTED_RESOLVE "*) ;; *) return 1 ;; esac
            if [ "$DASH_PASS" = 'second pass' ] && [ "$(grep -c '^login$' "$calls")" = 1 ]; then
                printf 401
            elif [ -s "$jar_arg" ]; then
                printf 200
            else
                printf 401
            fi
            printf 'probe\n' >>"$calls"
            ;;
        *)
            [ -s "$jar_arg" ] || return 1
            args=" $* "
            case "$args" in *' -b '*" Origin: ${EXPECTED_ORIGIN:-https://$ip} "*) ;; *) return 1 ;; esac
            case "$args" in *' -u '* | *' Authorization: '* | *"$DASH_USER"* | *"$DASH_PASS"*) return 1 ;; esac
            if [ "$EXPECT_REQUEST" = 1 ]; then
                case "$args" in *' -D - '*) ;; *) return 1 ;; esac
                case "$args" in *' -H Content-Type: application/json '*) ;; *) return 1 ;; esac
                case "$args" in *' --data-binary @- '*) ;; *) return 1 ;; esac
                cat >"$request_body"
                [ "$(cat "$request_body")" = "$REQUEST_JSON" ] || return 1
            fi
            printf 'state'
            printf 'request\n' >>"$calls"
            ;;
        esac
    }
    source "$HERE/dashboard-session.sh"
    EXPECT_REQUEST=1
    out=$(printf '%s' "$REQUEST_JSON" | dashboard_curl -sSk -D - -H 'Content-Type: application/json' \
        --data-binary @- "https://$ip/api/control/symbolicfixture") || return 1
    [ "$out" = state ] && [ "$(grep -c '^login$' "$calls")" = 1 ] || return 1
    EXPECT_REQUEST=0
    out=$(dashboard_curl -sSk "https://$ip/api/state") || return 1
    [ "$out" = state ] && [ "$(grep -c '^login$' "$calls")" = 1 ] || return 1
    DASH_PASS='second pass'
    out=$(dashboard_curl -sSk "https://$ip/api/state") || return 1
    [ "$out" = state ] && [ "$(grep -c '^login$' "$calls")" = 2 ] || return 1
    EXPECTED_ORIGIN=https://fixture-next.local
    EXPECTED_RESOLVE=fixture-route
    out=$(dashboard_curl -sSk --resolve "$EXPECTED_RESOLVE" "$EXPECTED_ORIGIN/api/state") || return 1
    [ "$out" = state ] && [ "$(grep -c '^login$' "$calls")" = 3 ] || return 1
    jar_arg="$DASHBOARD_SESSION_DIR/cookies"
    dashboard_session_cleanup
    [ ! -e "$jar_arg" ] || return 1
    rm -f "$calls" "$request_body"
}

dashboard_session_self_test
