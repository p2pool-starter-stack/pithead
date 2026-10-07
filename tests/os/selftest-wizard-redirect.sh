#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/wizard-redirect-leg.sh"
source "$HERE/../../lib/pithead/12a-wizard-addresses.sh"
ip=192.0.2.10
ip() {
    case "$*" in
    '-j link show type bridge') printf '[{"ifname":"podman0"},{"ifname":"br-custom"}]' ;;
    '-j addr show scope global')
        printf '%s' '[{"ifname":"podman0","addr_info":[{"scope":"global","local":"10.88.0.1"}]},{"ifname":"br-custom","addr_info":[{"scope":"global","local":"10.89.0.1"}]},{"ifname":"enp1s0","addr_info":[{"scope":"global","local":"192.0.2.10"},{"scope":"global","local":"fd00::1"},{"scope":"link","local":"fe80::1"}]}]'
        ;;
    *) return 1 ;;
    esac
}
[ "$(wizard_host_addresses)" = '192.0.2.10 fd00::1' ]
[ "$(wizard_url_host fd00::1)" = '[fd00::1]' ]
[ "$(wizard_url_host 192.0.2.10)" = '192.0.2.10' ]
ip() { return 1; }
if wizard_host_addresses; then exit 1; fi

ok() { passes=$((passes + 1)); }
bad() { failures=$((failures + 1)); }
_ssh() { printf '10.88.0.2'; }
curl() {
    case "$*" in
    *'-w '*) printf 'Pithead setup\n%s' "$page_status" ;;
    *'http://pithead.local/'*) printf 'HTTP/1.1 301 Moved Permanently\r\nLocation: https://pithead.local/\r\n' ;;
    *) printf 'HTTP/1.1 %s Redirect\r\nLocation: https://%s/\r\n' "$redirect_status" "$target" ;;
    esac
}
passes=0 failures=0 target=$ip redirect_status=301 page_status=200
phase_wizard_redirect
[ "$passes" = 4 ] && [ "$failures" = 0 ]
# The original container redirect, a non-redirect and a wrong destination must all fail.
for target in 10.88.0.2 evil.example; do
    passes=0 failures=0
    phase_wizard_redirect
    [ "$failures" = 3 ]
done
target=$ip redirect_status=200 passes=0 failures=0
phase_wizard_redirect
[ "$failures" = 3 ]
redirect_status=301 page_status=401 passes=0 failures=0
phase_wizard_redirect
[ "$failures" = 2 ]
page_status=200 redirect_status=308 passes=0 failures=0
phase_dashboard_redirect
[ "$passes" = 1 ] && [ "$failures" = 0 ]
target=10.88.0.2 passes=0 failures=0
phase_dashboard_redirect
[ "$failures" = 1 ]
for wiring in 'phases/boot.sh' 'phases/provision-initial.sh'; do
    grep -q 'phase_wizard_redirect' "$HERE/$wiring"
done
grep -q 'phase_dashboard_redirect' "$HERE/phases/provision-initial.sh"
grep -q 'wizard-redirect-leg.sh' "$HERE/run.sh"
grep -q 'WIZARD_HOST_ADDRESSES="$host_addresses"' "$HERE/../../lib/pithead/12-firstboot-wizard.sh"
grep -q 'for arg in $host_addresses' "$HERE/../../lib/pithead/12-firstboot-wizard.sh"
printf 'selftest-wizard-redirect: PASS\n'
