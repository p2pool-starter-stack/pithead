#!/usr/bin/env bash
# Pure controls for provision's calculator asset attestation; no guest or services.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/appliance-address-watch-leg.sh"
source "$SCRIPT_DIR/appliance-earnings-leg.sh"
ip=192.0.2.1
fixture=good
ok() { passes=$((passes + 1)); }
bad() { failures=$((failures + 1)); }
dashboard_curl() {
    [ "$DASH_USER" = fixture-user ] && [ "$DASH_PASS" = fixture-password ] || return 1
    [ "$1" = -fsSk ] && [ "$2" = -m ] && [ "$3" = 15 ] || return 1
    [ "$4" = -w ] && [ "$5" = '\n%{http_code}' ] || return 1
    local asset="${6#https://$ip/static/}" body code=200
    body=$(cat "$SCRIPT_DIR/../../dashboard/mining_dashboard/web/static/$asset")
    case "$fixture:$asset" in
    old-parser:app/logic.mjs) body='export function parseHashrate(s) { return parseFloat(s); }' ;;
    old-consumer:app/earnings.mjs) body='export const EarningsCard = () => null;' ;;
    empty:app/logic.mjs) body='' ;;
    missing:app/logic.mjs) return 22 ;;
    redirect:app/logic.mjs) code=302 ;;
    login-page:app/logic.mjs) body='<html>Sign in</html>' ;;
    esac
    printf '%s\n%s' "$body" "$code"
}
passes=0 failures=0
phase_provision_earnings_assets fixture-user fixture-password
[ "$passes" = 2 ] && [ "$failures" = 0 ]
for fixture in old-parser old-consumer empty missing redirect login-page; do
    passes=0 failures=0
    if phase_provision_earnings_assets fixture-user fixture-password; then
        echo "incorrect PASS for $fixture" >&2
        exit 1
    fi
    [ "$failures" -gt 0 ]
done
passes=0 failures=0
if phase_provision_earnings_assets fixture-user ''; then
    echo 'incorrect PASS without captured login' >&2
    exit 1
fi
[ "$passes" = 0 ] && [ "$failures" = 1 ]
control=$(mktemp -d -t earnings-assets.XXXXXX)
trap 'rm -rf "$control"' EXIT
mkdir -p "$control/tests/os" "$control/dashboard/mining_dashboard/web/static/app"
SCRIPT_DIR="$control/tests/os"
for fixture in absent-source empty-source; do
    passes=0 failures=0
    if phase_provision_earnings_assets fixture-user fixture-password 2>/dev/null; then
        echo "incorrect PASS for $fixture" >&2
        exit 1
    fi
    [ "$passes" = 0 ] && [ "$failures" = 1 ]
    touch "$control/dashboard/mining_dashboard/web/static/app/logic.mjs"
done
echo 'selftest-earnings-assets: PASS (two served assets; nine refusal controls)'
