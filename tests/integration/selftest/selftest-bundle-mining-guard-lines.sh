#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -P "$HERE/../../.." && pwd -P)"
PASS=0
FAIL=0
check() {
    if [ "$2" = ok ]; then
        PASS=$((PASS + 1))
        echo "  ok   — $1"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL — $1"
    fi
}

echo "== support-bundle keeps the dashboard's xmrig-proxy stop and readmit lines past the log tail (#4165) =="
work="$(mktemp -d "${TMPDIR:-/tmp}/bundle-guard.XXXXXX")"
trap 'rm -rf "$work"' EXIT
stop='2026-11-16 22:43:41,391 [WARNING] Mining work is not valid (Monero node container is not running) — stopping xmrig-proxy so workers fail over to their backup pools.'
readmit='2026-11-16 22:45:39,309 [INFO] Required nodes recovered — started xmrig-proxy to readmit workers, 117s after it was stopped.'
{
    echo "$stop"
    echo "$readmit"
    for i in $(seq 1 300); do echo "2026-11-16 23:00:00,000 [INFO] poll $i"; done
} >"$work/dashboard.log"

(
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    source "$REPO/pithead" </dev/null >/dev/null 2>&1
    doctor_json() { echo '{}'; }
    docker() {
        [ "$1" = compose ] || return 1
        shift
        case "$1" in
        ps)
            [[ "$*" == *--format* ]] && echo dashboard || echo "dashboard running"
            ;;
        logs)
            if [[ "$*" == *"--tail 200"* ]]; then tail -n 200 "$work/dashboard.log"; else cat "$work/dashboard.log"; fi
            ;;
        esac
    }
    stack_support_bundle >/dev/null 2>&1
)
archive="$(ls "$work"/support-bundle-*.tar.gz 2>/dev/null | head -n1)"
[ -n "$archive" ] && check "the bundle archive was written" ok || check "the bundle archive was written" no
guard="$(tar -xzOf "$archive" bundle/logs/dashboard-mining-guard.log 2>/dev/null)"
tail200="$(tar -xzOf "$archive" bundle/logs/dashboard.log 2>/dev/null)"
case "$tail200" in *"Mining work is not valid"*) rolled=no ;; *) rolled=ok ;; esac
check "the stop line has rolled out of the 200-line dashboard log" "$rolled"
case "$guard" in *"Mining work is not valid (Monero node container is not running)"*) s=ok ;; *) s=no ;; esac
check "the guard log carries the stop line" "$s"
case "$guard" in *"to readmit workers, 117s after it was stopped"*) r=ok ;; *) r=no ;; esac
check "the guard log carries the readmission line" "$r"
case "$guard" in *"poll "*) n=no ;; *) n=ok ;; esac
check "the guard log carries only guard lines" "$n"

echo "selftest-bundle-mining-guard-lines: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
