# shellcheck shell=bash
dashboard_api_request() {
    local method="$1" path="$2" body="${3:-}" output="${4:-body}" user form mode request curl_output authenticated_request
    case "$method:$output" in GET:body | GET:headers | GET:status | POST:body | POST:status) ;; *) return 2 ;; esac
    case "$output" in
    body) curl_output=-fsS ;;
    headers) curl_output=-fsSI ;;
    status) curl_output="-sS -o /dev/null -w '%{http_code}'" ;;
    esac
    if [ "$method" = GET ]; then
        request="curl $curl_output -b \"\$jar\" --max-time 10 $(quote_arg "http://127.0.0.1:8000$path")"
    else
        request="curl $curl_output -b \"\$jar\" -H 'Origin: http://127.0.0.1:8000' -H 'Content-Type: application/json' -H 'X-Pithead-Control: 1' -X POST --data-binary @- --max-time 60 $(quote_arg "http://127.0.0.1:8000$path")"
    fi
    mode=$(rx 'jq -r '\''if (.dashboard.auth.password // "") != "" then "legacy" elif ((.dashboard.auth.users // []) | length) > 0 then "named" else "off" end'\'' config.json' 2>/dev/null) || return 1
    if [ "$mode" = off ]; then
        printf '%s' "$body" | rx "jar=/dev/null; $request" --stdin 2>/dev/null
        return
    fi
    [ -n "${IT_DASHBOARD_PASSWORD:-}" ] || return 1
    if [ "$mode" = legacy ]; then
        user="$(env_on_box DASHBOARD_AUTH_USER)" || return 1
    else
        user="${IT_DASHBOARD_USER:-$(rx 'jq -r '\''first(.dashboard.auth.users[] | select(.role == "admin") | .name) // empty'\'' config.json' 2>/dev/null)}"
        [ -n "$user" ] || return 1
    fi
    form=$(printf '%s\0%s' "$user" "$IT_DASHBOARD_PASSWORD" |
        python3 -c 'import sys, urllib.parse; u, p = sys.stdin.buffer.read().split(b"\0", 1); print(urllib.parse.urlencode({"username": u.decode(), "password": p.decode()}), end="")') || return 1
    if [ "$method" = GET ]; then
        authenticated_request="case \"\$code\" in 303) $request ;; 404 | 405) jar=/dev/null; $request ;; *) exit 1 ;; esac"
    else
        authenticated_request="[ \"\$code\" = 303 ] && $request"
    fi
    {
        printf '%s\0' "$form"
        printf '%s' "$body"
    } |
        rx "IFS= read -r -d '' login; jar=\$(mktemp); trap 'rm -f \"\$jar\"' EXIT; code=\$(printf '%s' \"\$login\" | curl -sS -c \"\$jar\" -H 'Origin: http://127.0.0.1:8000' --data-binary @- -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8000/login 2>/dev/null); $authenticated_request" --stdin 2>/dev/null
}

dashboard_api_get() { dashboard_api_request GET "$1"; }
dashboard_api_headers() { dashboard_api_request GET "$1" '' headers; }
dashboard_api_status() { dashboard_api_request "$1" "$2" "${3:-}" status; }
api_state() { dashboard_api_get /api/state; }
