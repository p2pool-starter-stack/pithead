#!/usr/bin/env bash
# tor_recovery_info takes the outgoing count from the in-container helper, never from the restricted
# get_info, whose 0 is redacted (#2921). An unavailable count is null: neither "0 outgoing" (the
# recovery signature) nor "> 0" (its verification) is then true.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=lib/pithead/02e-tor-recovery.sh
source "$ROOT/lib/pithead/02e-tor-recovery.sh"

env_get() { case "$1" in MONERO_NODE_USERNAME) echo u ;; MONERO_NODE_PASSWORD) echo p ;; MONERO_RPC_URL) echo http://x ;; esac }
# The restricted listener answers 0 for the count, whatever the truth.
curl() {
    cat >/dev/null
    echo '{"status":"OK","synchronized":false,"height":42,"restricted":true,"outgoing_connections_count":0}'
}
HELPER_OUT=""
HELPER_RC=0
docker() {
    [ "$*" = "exec monerod /usr/local/bin/monerod-peers.sh" ] || return 9
    printf '%s' "$HELPER_OUT"
    return "$HELPER_RC"
}

count() { tor_recovery_info | jq -c .outgoing_connections_count; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

HELPER_OUT='{"outgoing":7,"incoming":1,"white":3,"grey":4}'
[ "$(count)" = 7 ] || fail "the helper's count must replace the redacted 0"

HELPER_OUT='{"outgoing":0,"incoming":0,"white":0,"grey":0}'
[ "$(count)" = 0 ] || fail "a real zero must read as 0"
jq -e '.outgoing_connections_count == 0 and .synchronized == false' <<<"$(tor_recovery_info)" >/dev/null || fail "a real zero must satisfy the signature's peer clause"

for bad in '' 'not json' '{"outgoing":"7"}' '{"outgoing":-1}' '{"incoming":3}'; do
    HELPER_OUT=$bad
    [ "$(count)" = null ] || fail "helper output '$bad' must read as unavailable (null)"
done
HELPER_OUT='{"outgoing":7}'
HELPER_RC=3
[ "$(count)" = null ] || fail "a failing helper must read as unavailable (null)"
if jq -e '.outgoing_connections_count == 0' <<<"$(tor_recovery_info)" >/dev/null; then fail "unavailable read as zero peers"; fi
if jq -e '.status == "OK" and .outgoing_connections_count > 0' <<<"$(tor_recovery_info)" >/dev/null; then fail "unavailable read as peers present"; fi
echo "tor_recovery_info: the count comes from the helper; unavailable is never zero or positive"
