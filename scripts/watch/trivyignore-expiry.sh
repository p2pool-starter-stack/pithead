#!/usr/bin/env bash
# Report .config/trivyignore mutes that are expired or expire within 7 days; report-only, exit 0.
# Usage: trivyignore-expiry.sh [ignorefile]   |   trivyignore-expiry.sh --self-test
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WARN_DAYS=7

plus_days() { # <date> <days>
    date -u -d "$1 +$2 days" +%F 2>/dev/null || date -u -j -v"+$2d" -f %F "$1" +%F
}

report() { # <ignorefile> <today>
    local file="$1" today="$2" soon id exp rest rows="" expired=0 expiring=0 undated=0
    soon="$(plus_days "$today" "$WARN_DAYS")"
    while read -r id rest; do
        case "$id" in '' | '#'*) continue ;; esac
        exp="$(printf '%s\n' "$rest" | tr ' ' '\n' | sed -n 's/^exp:\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)$/\1/p' | head -n1)"
        if [ -z "$exp" ]; then
            rows="${rows}| \`$id\` | none | **NO exp: DATE** |"$'\n'
            undated=$((undated + 1))
        elif [[ "$exp" < "$today" ]]; then
            rows="${rows}| \`$id\` | $exp | **EXPIRED** |"$'\n'
            expired=$((expired + 1))
        elif [[ "$exp" < "$soon" || "$exp" == "$soon" ]]; then
            rows="${rows}| \`$id\` | $exp | expires within $WARN_DAYS days |"$'\n'
            expiring=$((expiring + 1))
        fi
    done <"$file"
    if [ -n "$rows" ]; then
        printf '\n### Mute expiry\n\n| finding ID | exp | verdict |\n|---|---|---|\n%s' "$rows"
    else
        printf '\n### Mute expiry\n\nNo mute is expired, undated or expiring within %s days.\n' "$WARN_DAYS"
    fi
    printf '\n<!-- trivyignore-expiry: expired=%s expiring=%s undated=%s -->\n' "$expired" "$expiring" "$undated"
}

if [ "${1:-}" = "--self-test" ]; then
    fx="$(mktemp)"
    trap 'rm -f "$fx"' EXIT
    printf '# c\nCVE-OLD exp:2026-01-01\nCVE-SOON exp:2026-11-25\nCVE-FAR exp:2027-01-01\nCVE-NONE\n' >"$fx"
    out="$(report "$fx" 2026-11-20)"
    fail=0
    chk() { printf '%s' "$out" | grep -qF -- "$1" || {
        echo "self-test FAIL: $1"
        fail=1
    }; }
    chk "CVE-OLD\` | 2026-01-01 | **EXPIRED**"
    chk "CVE-SOON\` | 2026-11-25 | expires within 7 days"
    chk "CVE-NONE\` | none | **NO exp: DATE**"
    chk 'expired=1 expiring=1 undated=1'
    if printf '%s' "$out" | grep -qF CVE-FAR; then
        echo "self-test FAIL: far-dated mute reported"
        fail=1
    fi
    [ "$fail" = 0 ] && echo "trivyignore-expiry self-test OK"
    exit "$fail"
fi

report "${1:-$ROOT/.config/trivyignore}" "$(date -u +%F)"
