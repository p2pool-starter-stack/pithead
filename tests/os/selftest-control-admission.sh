#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/provision-browser-submit.sh"
source "$HERE/appliance-config-approval-leg.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# shellcheck disable=SC2034
ip=fixture
body='{"id":"12345678-1234-4234-8234-123456789abc","confirm":"APPLY"}'
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
date() { cat "$scratch/clock"; }
sleep() {
    printf '%s\n' "$(($(cat "$scratch/clock") + $1))" >"$scratch/clock"
}
_ssh() { printf 'Result=success\nActiveState=inactive\nqueued=0\nclaimed=0\n'; }
dashboard_curl() {
    local url="${!#}" count cap=""
    case "$url" in
    *'/api/control/result?id='*)
        printf 'x\n' >>"$scratch/polls"
        if [ -s "$scratch/accepted" ] && [ "$(wc -l <"$scratch/polls")" -gt 1 ]; then
            printf '{"status":"applied"}\n200'
        else
            printf '{"status":"previewed"}\n200'
        fi
        ;;
    *'/api/control/commit' | *'/api/control/backup')
        [ "$(cat)" = "$body" ] || return 90
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -m ]; then cap="$2"; fi
            shift
        done
        printf '%s\n' "$cap" >>"$scratch/posts"
        count=$(wc -l <"$scratch/posts")
        if [ "$shape" = refused ] || { [ "$shape" = recovered ] && [ "$count" -eq 1 ]; }; then
            printf '\n000'
            return 7
        fi
        if [ "$shape" = rejected ]; then
            printf '{"error":"refused"}\n403'
            return 0
        fi
        case "$shape" in
        body7)
            printf 'not-empty\n000'
            return 7
            ;;
        http7)
            printf '\n200'
            return 7
            ;;
        esac
        printf 'x\n' >>"$scratch/accepted"
        case "$shape" in
        lost)
            printf '\n000'
            return 52
            ;;
        proxy) printf 'unavailable\n503' ;;
        empty_proxy) printf '\n503' ;;
        *) printf '{"id":"12345678-1234-4234-8234-123456789abc","status":"accepted"}\n202' ;;
        esac
        ;;
    *) return 91 ;;
    esac
}
run_case() {
    local shape="$1" seconds="$2" posts="$3" accepted="$4" polls="$5" want_rc="$6" route="${7:-commit}" result rc=0
    local file
    printf '100\n' >"$scratch/clock"
    for file in posts accepted polls; do : >"$scratch/$file"; done
    result=$(dashboard_control_request "$route" "$body" "$seconds" 2>"$scratch/evidence") || rc=$?
    [ "$rc" -eq "$want_rc" ] || fail "$shape: wrong verdict"
    [ "$(wc -l <"$scratch/posts")" -eq "$posts" ] || fail "$shape: wrong POST count"
    [ "$(wc -l <"$scratch/accepted")" -eq "$accepted" ] || fail "$shape: wrong accepted count"
    [ "$(wc -l <"$scratch/polls")" -eq "$polls" ] || fail "$shape: polled an undelivered request or lost completion"
    if [ "$want_rc" -eq 0 ]; then
        jq -e '.status == "applied" and .id == "12345678-1234-4234-8234-123456789abc"' <<<"$result" >/dev/null || fail "$shape: wrong result"
    else
        [ -z "$result" ] || fail "$shape: returned a stale preview"
    fi
    printf 'PASS: %s %s\n' "$route" "$shape"
}
run_case recovered 30 2 1 2 0
run_case refused 30 3 0 0 1
run_case refused 4 2 0 0 1
[ "$(tail -n 1 "$scratch/posts")" = 1 ] || fail 'reconnect exceeded the remaining deadline'
run_case refused 0 1 0 0 1
run_case lost 30 1 1 2 0
run_case proxy 30 1 1 2 0
run_case empty_proxy 30 1 1 2 0
run_case body7 30 1 0 0 1
run_case http7 30 1 0 0 1
run_case accepted 30 1 1 2 0
run_case rejected 30 1 0 0 1
run_case recovered 30 2 1 2 0 backup
printf 'control-admission: 12 cases passed\n'
