#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../lib.sh"
echo "== dashboard guest session transport =="
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/case"
export ARGV_LOG="$work/argv" BODY_LOG="$work/body" TARGET_LOG="$work/targets"
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$ARGV_LOG"
printf '\n' >>"$ARGV_LOG"
url=${!#}
if [[ $url == */login ]]; then
    cat >"$BODY_LOG"
    previous=
    for arg; do
        [ "$previous" != -c ] || printf 'session\n' >"$arg"
        previous=$arg
    done
    printf '%s' "${LOGIN_CODE:-303}"
    exit 0
fi
printf '%s\n' "$url" >>"$TARGET_LOG"
if [ "${EXPECT_COOKIE:-0}" = 1 ]; then
    previous= found=0
    for arg; do
        if [ "$previous" = -b ] && [ "$(cat "$arg")" = session ]; then found=1; fi
        previous=$arg
    done
    [ "$found" = 1 ]
else
    case " $* " in *' -b '*) exit 91 ;; esac
fi
printf '{"ok":true}\n'
CURL
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"

reset_case() {
    : >"$ARGV_LOG"
    : >"$BODY_LOG"
    : >"$TARGET_LOG"
    unset LOGIN_CODE EXPECT_COOKIE IT_DASHBOARD_USER IT_DASHBOARD_PASSWORD
}

cd "$work/case"
reset_case
printf '{"dashboard":{"auth":{"password":"","users":[]}}}\n' >config.json
[ "$(dashboard_guest_get http://fixture.invalid/api/state 5)" = '{"ok":true}' ]
[ ! -s "$BODY_LOG" ] && [ "$(wc -l <"$TARGET_LOG" | tr -d ' ')" = 1 ]

reset_case
printf '{"dashboard":{"auth":{"username":"operator","password":"legacy-secret","users":[]}}}\n' >config.json
EXPECT_COOKIE=1 dashboard_guest_get http://fixture.invalid/api/state 5 >response
[ "$(cat response)" = '{"ok":true}' ]
[ "$(cat "$BODY_LOG")" = 'username=operator&password=legacy-secret' ]
! grep -Fq legacy-secret "$ARGV_LOG"
! grep -Eq 'Authorization: Basic|(^|[[:space:]])-u([[:space:]]|$)' "$ARGV_LOG"

reset_case
printf '{"dashboard":{"auth":{"password":"","users":[{"name":"named-admin","role":"admin","password_hash":"fixture"}]}}}\n' >config.json
export IT_DASHBOARD_USER=named-admin IT_DASHBOARD_PASSWORD=named-secret EXPECT_COOKIE=1
[ "$(dashboard_guest_get http://fixture.invalid/api/state 5)" = '{"ok":true}' ]
[ "$(cat "$BODY_LOG")" = 'username=named-admin&password=named-secret' ]
! grep -Fq named-secret "$ARGV_LOG"
! grep -Eq 'Authorization: Basic|(^|[[:space:]])-u([[:space:]]|$)' "$ARGV_LOG"

reset_case
printf '{"dashboard":{"auth":{"username":"operator","password":"legacy-secret","users":[]}}}\n' >config.json
export LOGIN_CODE=401
if dashboard_guest_get http://fixture.invalid/api/state 5 >/dev/null 2>&1; then exit 1; fi
[ ! -s "$TARGET_LOG" ]

reset_case
export LOGIN_CODE=404
[ "$(dashboard_guest_get http://fixture.invalid/api/state 5)" = '{"ok":true}' ]
[ "$(wc -l <"$TARGET_LOG" | tr -d ' ')" = 1 ]
! grep -Eq 'Authorization: Basic|(^|[[:space:]])-u([[:space:]]|$)' "$ARGV_LOG"

printf 'dashboard guest session self-test passed\n'
