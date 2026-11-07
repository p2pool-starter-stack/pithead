# shellcheck shell=bash
dashboard_curl() {
    local jar="${DASHBOARD_SESSION_DIR:?}/cookies" code identity origin arg previous=""
    local -a session_route=()
    origin=$(printf '%s' "${!#}" |
        python3 -c 'import sys, urllib.parse; u=urllib.parse.urlsplit(sys.stdin.read()); print(u.scheme + "://" + u.netloc)') || return 1
    for arg in "$@"; do
        [ "$previous" != --resolve ] || session_route+=(--resolve "$arg")
        previous="$arg"
    done
    identity=$(printf '%s\0%s' "$origin" "$DASH_USER" | sha256sum | cut -d' ' -f1) || return 1
    if [ ! -s "$jar" ] || [ "$(cat "$jar.user" 2>/dev/null)" != "$identity" ]; then
        dashboard_session_login "$origin" "$identity" "${session_route[@]}" || return 1
    else
        code=$(curl -sSk "${session_route[@]}" -b "$jar" -o /dev/null -w '%{http_code}' -m 8 \
            "$origin/api/auth/session" 2>/dev/null || true)
        [ "$code" = 200 ] || dashboard_session_login "$origin" "$identity" "${session_route[@]}" || return 1
    fi
    curl -b "$jar" -H "Origin: $origin" "$@"
}
dashboard_session_login() {
    local origin="$1" identity="$2" form code jar="${DASHBOARD_SESSION_DIR:?}/cookies" fresh
    shift 2
    form=$(printf '%s\0%s' "$DASH_USER" "$DASH_PASS" |
        python3 -c 'import sys, urllib.parse; u, p = sys.stdin.buffer.read().split(b"\0", 1); print(urllib.parse.urlencode({"username": u.decode(), "password": p.decode()}), end="")') || return 1
    fresh=$(mktemp "$DASHBOARD_SESSION_DIR/cookies.XXXXXX") || return 1
    code=$(printf '%s' "$form" |
        curl -sSk "$@" -c "$fresh" -H "Origin: $origin" --data-binary @- -o /dev/null \
            -w '%{http_code}' -m 8 "$origin/login" 2>/dev/null || true)
    if [ "$code" != 303 ] || [ ! -s "$fresh" ]; then
        rm -f "$fresh"
        return 1
    fi
    mv -f "$fresh" "$jar" || return 1
    printf '%s' "$identity" >"$jar.user"
}
dashboard_session_cleanup() {
    local jar="${DASHBOARD_SESSION_DIR:?}/cookies"
    rm -f "$jar" "$jar.user"
    rmdir "$DASHBOARD_SESSION_DIR" 2>/dev/null || true
}
