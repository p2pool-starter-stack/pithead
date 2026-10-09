#!/usr/bin/env bash
# Pure fixture controls for the TLS asset checks in the provision address-watch leg.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/appliance-address-watch-leg.sh"
STATIC="$HERE/../../dashboard/mining_dashboard/web/static"
ip=192.0.2.1
fixture=good
ok() { passes=$((passes + 1)); }
bad() { failures=$((failures + 1)); }
dashboard_curl() {
    [ "$DASH_USER" = fixture-user ] && [ "$DASH_PASS" = fixture-password ]
    [ "$1" = -fsSk ] && [ "$2" = -m ] && [ "$3" = 15 ]
    [ "$4" = -w ] && [ "$5" = '\n%{http_code}' ]
    local path="${6#https://$ip/static/}" body code=200
    body=$(cat "$STATIC/$path")
    case "$fixture:$path" in
    old-close:system/osupdate.mjs)
        body=${body//'this.cancel()}>Close</button>'/'this.setState({ phase: "idle", error: "" })}>Close</button>'}
        ;;
    missing-error-pane:system/osupdate.mjs) body=${body//'if (phase === "error")'/'if (phase === "absent")'} ;;
    old-draft-reset:config/configview.mjs) body=${body/'this.setState({ phase: "form", result: null })'/'this.load()'} ;;
    missing-module:app/connectionrecovery.mjs) return 22 ;;
    redirect:app/connectionrecovery.mjs) code=302 ;;
    server-error:dashboard.js) return 22 ;;
    missing-compare:app/connectionrecovery.mjs) body=${body/'compare the certificate'/'ignore the certificate'} ;;
    missing-stop:app/connectionrecovery.mjs) body=${body/'Stop if they do not'/'Proceed if they do not'} ;;
    missing-trigger:dashboard.js) body=${body/'disconnectedSince >= 60000'/'disconnectedSince >= Infinity'} ;;
    missing-failure-clock:dashboard.js) body=${body/'disconnectedSince = now();'/'disconnectedSince = null;'} ;;
    missing-prop:dashboard.js) body=${body/'recoveryNeeded=${p.recoveryNeeded}'/'recoveryNeeded=${false}'} ;;
    unsafe-command:app/connectionrecovery.mjs) body=${body/' -sha256</code>'/' -sha256; false</code>'} ;;
    esac
    printf '%s\n%s' "$body" "$code"
}
_ssh() {
    [ "$1" = 'openssl x509 -in /data/pithead/data/tls/wizard.crt -noout -fingerprint -sha256' ]
    case "$fixture" in
    failed-command) return 1 ;;
    malformed-fingerprint)
        echo 'sha256 Fingerprint=AB:CD'
        return
        ;;
    esac
    printf 'sha256 Fingerprint='
    printf 'AB:%.0s' {1..31}
    printf 'CD\n'
}
passes=0 failures=0
phase_provision_dashboard_recovery fixture-user fixture-password
[ "$passes" = 5 ] && [ "$failures" = 0 ]
for fixture in old-close missing-error-pane old-draft-reset missing-module redirect server-error missing-compare missing-stop \
    missing-trigger missing-failure-clock missing-prop unsafe-command failed-command malformed-fingerprint; do
    passes=0 failures=0
    if phase_provision_dashboard_recovery fixture-user fixture-password; then
        echo "incorrect PASS for $fixture" >&2
        exit 1
    fi
    [ "$failures" -gt 0 ]
done
passes=0 failures=0
if phase_provision_dashboard_recovery fixture-user ''; then
    echo 'incorrect PASS without the captured login' >&2
    exit 1
fi
[ "$passes" = 0 ] && [ "$failures" = 1 ]
echo 'selftest-dashboard-recovery: PASS (five deployed assertions; 15 refusal controls)'
