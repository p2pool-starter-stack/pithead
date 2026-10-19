#!/usr/bin/env bash
# The shared Tor control dial builder both harnesses use (#2619): attempt 1 is the original request,
# each retry names its own SOCKS user, and the appliance leg loads the same builder.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/tor-control-dial.sh
source "$HERE/../lib/tor-control-dial.sh"

socks=192.0.2.25:9050
echo "== Attempt 1 is the original request in both harnesses =="
assert_eq "three attempts" "$TOR_CONTROL_DIAL_ATTEMPTS" 3
assert_eq "attempt 1 is the original e2e request, byte for byte" \
    "$(tor_control_dial_cmd docker curl "$socks" 1)" \
    'docker exec monerod curl -s -o /dev/null -m 30 --socks5-hostname 192.0.2.25:9050 http://1.1.1.1/'
assert_eq "attempt 1 is the original appliance request, byte for byte" \
    "$(tor_control_dial_cmd podman /usr/bin/curl "$socks" 1)" \
    'podman exec monerod /usr/bin/curl -s -o /dev/null -m 30 --socks5-hostname 192.0.2.25:9050 http://1.1.1.1/'

echo "== Each retry allows 45 s and names its own SOCKS user =="
users=""
for attempt in 2 3; do
    cmd="$(tor_control_dial_cmd docker curl "$socks" "$attempt")"
    assert_contains "attempt $attempt allows 45 s" "$cmd" ' -m 45 '
    assert_contains "attempt $attempt dials through the same SOCKS" "$cmd" "--socks5-hostname $socks http://1.1.1.1/"
    users="$users$(grep -o -- '--proxy-user [^ ]*' <<<"$cmd")"$'\n'
done
assert_eq "retries use distinct SOCKS users, so Tor builds a fresh circuit for each" \
    "$(grep -c . <<<"$users")/$(sort -u <<<"$users" | grep -c .)" "2/2"

echo "== The appliance leg loads the same builder =="
(
    # shellcheck source=tests/os/appliance-egress-leg.sh
    . "$HERE/../../os/appliance-egress-leg.sh"
    declare -F tor_control_dial_cmd >/dev/null
)
assert_eq "appliance-egress-leg.sh defines the builder on load" "$?" 0

echo "selftest-tor-control-dial: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
