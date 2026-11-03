# shellcheck shell=bash
dashboard_guest_get() (
    set +x
    local url="$1" limit="$2" mode user form origin jar code
    shift 2
    mode=$(jq -r 'if (.dashboard.auth.password // "") != "" then "legacy" elif ((.dashboard.auth.users // []) | length) > 0 then "named" else "off" end' config.json) || return 1
    if [ "$mode" = off ]; then
        curl -fsS --max-time "$limit" "$@" "$url"
        return
    fi
    origin=$(printf '%s' "$url" | python3 -c 'import sys, urllib.parse; u=urllib.parse.urlsplit(sys.stdin.read()); print(u.scheme + "://" + u.netloc)') || return 1
    if [ "$mode" = legacy ] && [ -z "${IT_DASHBOARD_PASSWORD:-}" ]; then
        form=$(jq -c '[.dashboard.auth.username // "admin", .dashboard.auth.password]' config.json |
            python3 -c 'import json, sys, urllib.parse; u,p=json.load(sys.stdin); print(urllib.parse.urlencode({"username":u,"password":p}), end="")') || return 1
    else
        [ -n "${IT_DASHBOARD_PASSWORD:-}" ] || return 1
        if [ "$mode" = legacy ]; then
            user="${IT_DASHBOARD_USER:-$(jq -r '.dashboard.auth.username // "admin"' config.json)}"
        else
            user="${IT_DASHBOARD_USER:-$(jq -r 'first(.dashboard.auth.users[] | select(.role == "admin") | .name) // empty' config.json)}"
        fi
        [ -n "$user" ] || return 1
        form=$(printf '%s\0%s' "$user" "$IT_DASHBOARD_PASSWORD" |
            python3 -c 'import sys, urllib.parse; u,p=sys.stdin.buffer.read().split(b"\0",1); print(urllib.parse.urlencode({"username":u.decode(),"password":p.decode()}), end="")') || return 1
    fi
    jar=$(mktemp) || return 1
    trap 'rm -f "$jar"' EXIT
    code=$(printf '%s' "$form" | curl -sS --max-time "$limit" "$@" -c "$jar" -H "Origin: $origin" --data-binary @- -o /dev/null -w '%{http_code}' "$origin/login") || return 1
    if [ "$code" = 404 ] || [ "$code" = 405 ]; then
        curl -fsS --max-time "$limit" "$@" "$url"
        return
    fi
    [ "$code" = 303 ] || return 1
    curl -fsS --max-time "$limit" -b "$jar" "$@" "$url"
)
